require "test_helper"
require "fileutils"
require "securerandom"
require "support/actor_provisioning"
require "support/runner_grant"
require "support/steward_session"

# Opt-in HTTP measurement, with the ordinary isolated E2E world and public grants.
# From e2e/: E2E_AGENT_API_LOAD=1 bundle exec rake agent_api_load
# Uses no model, daemon, or external service. The durations include the development
# server, logging, scheduling and loopback HTTP; they are not production capacity.
class AgentAPILoadTest < Minitest::Test
  WIDTHS = [16, 32].freeze
  TASKS_PER_WIDTH = 128
  EVENT_READS_PER_WORKER = 24
  REPORT_PATH = File.expand_path("../artifacts/agent_api_load/last.json", __dir__)

  class MeasuredTransport
    def initialize(base_url:, rows:, lock:)
      @transport = CybrosAgent::HttpTransport.new(base_url: base_url)
      @rows, @lock = rows, lock
    end

    def call(path, **options)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @transport.call(path, **options)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      # Never retain headers, credentials, request bodies or row identities.
      family = path.gsub(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/, ":id")
      @lock.synchronize do
        @rows << { family: "#{options.fetch(:method, :get)} #{family}",
          status: response.status, milliseconds: elapsed * 1000 }
      end
      response
    end
  end

  def setup
    skip "set E2E_AGENT_API_LOAD=1 for the isolated HTTP measurement" unless ENV["E2E_AGENT_API_LOAD"] == "1"

    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @member = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    @workspace = @member.workspaces.create(name: "Agent API load", idempotency_key: SecureRandom.uuid)
    browser = E2E::StewardSession.actor(base_url: @base_url, human: @actor)
    device = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
    E2E::DeviceAuthorizationBudget.consume
    authorization = device.request_runner_authorization(registration_identifier: "api-load",
      runner_display_name: "API load", executor_kind: "runner")
    E2E::RunnerGrant.visit_connection(actor: browser, authorization: authorization)
    E2E::RunnerGrant.connect_in_browser(actor: browser, authorization: authorization)
    @executor_credential = device.await_credentials(authorization).executor_access_token
    executor = CybrosAgent::ExecutorClient.new(base_url: @base_url, credential: @executor_credential)
    @executor_id = executor.executor.executor.public_id
    executor.announce(tools: [{ "name" => "read", "effect_profile" =>
      { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none" }, "timeout_ms" => 120_000 }])
    E2E.hosts.start
    @report = { environment: "isolated development, loopback HTTP, no model calls",
      tasks_per_width: TASKS_PER_WIDTH, event_reads_per_worker: EVENT_READS_PER_WORKER, runs: [] }
  end

  def test_parallel_short_tasks_fit_the_credential_budgets
    WIDTHS.each do |width|
      rows, failures, lock = [], [], Mutex.new
      log_path = E2E.handle.fetch("env").fetch("RAILS_LOG_FILE")
      log_offset = File.size(log_path)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      threads = width.times.map do |worker|
        Thread.new do
          transport = MeasuredTransport.new(base_url: @base_url, rows: rows, lock: lock)
          member = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token, transport: transport)
          executor = CybrosAgent::ExecutorClient.new(base_url: @base_url,
            credential: @executor_credential, transport: transport)
          store = member.profile.store_entries
          entry = store.create(namespace: "api-load", key: "#{width}-#{worker}", value: {},
            idempotency_key: SecureRandom.uuid)
          context = nil
          (TASKS_PER_WIDTH / width).times do |iteration|
            context = member.workspace(@workspace.public_id).runs.start_tool_call(
              runner_executor_public_id: @executor_id, tool: "read", input: { "value" => iteration },
              idempotency_key: SecureRandom.uuid)
            task = executor.inbox_task(run_public_id: context.run_public_id, task_key: "relay")
            claimed = task.claim
            raise "claim not active" unless task.claim_status(claim_token: claimed.claim_token).active?

            executor.report_progress("run_public_id" => context.run_public_id,
              "task_key" => "relay", "claim_token" => claimed.claim_token, "text_tail" => "ready")
            task.commit(claim_token: claimed.claim_token, content: "ok")
            raise "loop did not complete" unless context.fetch.status == "completed"

            entry = store.update(entry.public_id, value: { "completed" => iteration + 1 }, lock_version: entry.lock_version)
          end
          EVENT_READS_PER_WORKER.times { context.events(limit: 1) }
          raise "store lost a write" unless store.fetch(entry.public_id).value.fetch("completed") == TASKS_PER_WIDTH / width
        rescue StandardError => error
          lock.synchronize do
            failures << { worker: worker, error: error.class.name, message: CybrosAgent::Redaction.call(error.message) }
          end
        end
      end
      threads.each(&:join)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      log = File.binread(log_path, File.size(log_path) - log_offset, log_offset)
      query_counts = log.scan(/Completed .*?ActiveRecord: [\d.]+ms \((\d+) queries/).flatten.map(&:to_i)
      cached_counts = log.scan(/Completed .*?ActiveRecord: [\d.]+ms \(\d+ queries, (\d+) cached/).flatten.map(&:to_i)
      run = { workers: width, seconds: elapsed.round(3), requests: rows.length,
        statuses: rows.group_by { |row| row.fetch(:status) }.transform_values(&:length),
        rails_completed_requests_with_query_counts: query_counts.length,
        rails_queries: query_counts.sum, rails_cached_queries: cached_counts.sum,
        rails_queries_p50: percentile(query_counts, 0.5),
        rails_queries_p95: percentile(query_counts, 0.95), failures: failures,
        families: rows.group_by { |row| row.fetch(:family) }.transform_values do |samples|
          durations = samples.map { |row| row.fetch(:milliseconds) }
          { requests: samples.length, p50_ms: percentile(durations, 0.5), p95_ms: percentile(durations, 0.95),
            max_ms: durations.max.round(2), statuses: samples.group_by { |row| row.fetch(:status) }.transform_values(&:length) }
        end }
      @report.fetch(:runs) << run
      FileUtils.mkdir_p(File.dirname(REPORT_PATH))
      File.write(REPORT_PATH, JSON.pretty_generate(@report))
      puts JSON.generate(run.except(:families))
      assert_empty failures
      refute rows.any? { |row| row.fetch(:status) == 429 }, "credential budget blocked #{width} workers"
      assert_operator query_counts.length, :>, 0, "Rails did not publish query counts in its request log"
    end
  end

  private

    def percentile(values, fraction)
      return if values.empty?

      sorted = values.sort
      sorted.fetch((sorted.length * fraction).ceil - 1).round(2)
    end
end
