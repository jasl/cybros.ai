# From e2e/: E2E_ASSETS_PREPARED=1 bundle exec ruby -Itest manual/realtime_capacity/nexus.rb
require "test_helper"
require "support/realtime_fixture"

module RealtimeCapacity
  class Server < E2E::NexusServer
    def self.register_database_cleanup(server) = E2E::NexusServer.register_database_cleanup(server)
    def self.unregister_database_cleanup(server) = E2E::NexusServer.unregister_database_cleanup(server)

    attr_reader :pid

    def preserve_log(destination)
      FileUtils.cp(@log_path, destination) if File.file?(@log_path)
    end

    private

      def env
        super.merge("RAILS_ENV" => "production", "WEB_CONCURRENCY" => "0", "RAILS_MAX_THREADS" => ENV.fetch("CAPACITY_THREADS", "1"),
          "SOLID_QUEUE_IN_PUMA" => "false", "RAILS_FORCE_SSL" => "false", "RAILS_ASSUME_SSL" => "false",
          "RUBYOPT" => "-r#{File.join(__dir__, "stdout.rb")}",
          "DISABLE_DATABASE_ENVIRONMENT_CHECK" => "1")
      end

      def db_env
        super.merge("RAILS_CACHE_DB_NAME" => db_name("cache"))
      end

      def prepare_databases
        # All four roles use this world's own names before production db tasks.
        raise "Non-isolated database" unless db_env.values.all? { |name| name.start_with?("cybros_nexus_") && name.include?("_e2e_#{@run_id}") }

        super
        run_rails("db:schema:load:cache", label: "cache_schema")
        acquire_asset_lock(File::LOCK_EX)
        run_rails("assets:precompile", label: "capacity_assets")
        acquire_asset_lock(File::LOCK_SH)
      end
  end
end

class RealtimeNexusCapacity < Minitest::Test
  include E2E::RealtimeFixture

  SDP = "v=0\r\na=fingerprint:sha-256 #{(["AA"] * 32).join(":")}\r\n".freeze

  def test_capacity
    input = nil
    output = File.expand_path("../../../artifacts/realtime_capacity", __dir__)
    FileUtils.mkdir_p(output)
    server = RealtimeCapacity::Server.new(nexus_root: E2E::NEXUS_ROOT)
    server.start
    ENV["E2E_BASE_URL"] = server.base_url
    ENV["E2E_NEXUS_OPERATOR"] = server.operator_handle_path
    puts "capacity server pid=#{server.pid} url=#{server.base_url}"
    $stdout.flush
    endpoints = []
    runs = []
    claims = []
    tiers = ENV.fetch("CAPACITY_TIERS", "1,10,25,50,100,200").split(",").map { |v| Integer(v) }
    readers = Integer(ENV.fetch("CAPACITY_READERS", "2"))
    raise "CAPACITY_READERS must be 1 or 2" unless [1, 2].include?(readers)
    group = nil
    tiers.each do |count|
      while runs.length < count
        if runs.length % 20 == 0
          base, _path, _http, _session, member_key, member, _transport, executor, key, workspace = prepare_realtime(start: false)
          executor.announce(services: { "agent" => { "tools" => [] }, "runner" => { "tools" => [{ "name" => "realtime_probe", "timeout_ms" => 3_600_000,
            "effect_profile" => { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
              "idempotency" => "intrinsic", "reconciliation" => "none" } }] } })
          executor_key = @runner_key
          group = [base, member_key, member, executor_key, executor, key, workspace]
        end
        base, member_key, member, executor_key, executor, key, workspace = group
        run = member.workspace(workspace.public_id).runs.start_tool_call(
          runner_executor_public_id: executor.executor.executor.public_id, tool: "realtime_probe",
          input: {}, idempotency_key: SecureRandom.uuid)
        runs << run
        await(seconds: 20) { run.task(key).task.status == "dispatched" }
        task = executor.inbox_task(run_public_id: run.run_public_id, task_key: key)
        claim = task.claim
        claims << [task, claim.claim_token, member_key]
        task.extend(claim_token: claim.claim_token, timeout_ms: 3_600_000)
        connection = SecureRandom.uuid_v7
        task.offer_realtime(claim_token: claim.claim_token, connection_id: connection, sdp: SDP)
        assert_predicate run.tasks_context(key).answer_realtime(connection_id: connection, sdp: SDP), :active?
        endpoints << { URL: "#{base}/agent_api/v1/workspaces/#{workspace.public_id}/runs/#{run.run_public_id}/tasks/#{key}/realtime", Token: member_key }
        endpoints << { URL: "#{base}/agent_api/v1/executor/inbox/#{run.run_public_id}/#{key}/realtime", Token: executor_key, Claim: claim.claim_token }
      end
      input = File.join(output, "endpoints.json")
      selected = endpoints.first(count * 2)
      selected = selected.select { |endpoint| endpoint[:Claim] } if readers == 1
      File.write(input, JSON.generate(selected), perm: 0o600)
      report = File.join(output, "nexus-#{count}-#{Time.now.to_i}.json")
      database_args = server.child_env.values_at("RAILS_APP_DB_NAME", "RAILS_CACHE_DB_NAME", "RAILS_QUEUE_DB_NAME", "RAILS_CABLE_DB_NAME")
        .flat_map { |name| ["--database", name] }
      command = ["python3", File.join(__dir__, "measure.py"), "--server", server.pid.to_s, "--output", report, *database_args, "--",
        File.join(output, "load"), "-mode", "http", "-input", input, "-count", count.to_s,
        "-readers", readers.to_s,
        "-duration", "#{ENV.fetch("CAPACITY_SECONDS", "20")}s"]
      assert system(*command), "load driver failed"
      result = JSON.parse(File.read(report))
      if ENV["CAPACITY_REQUIRE_SUCCESS"] == "1"
        assert_empty result.fetch("errors")
        assert_equal 0, result.fetch("permission_gaps"), "permission expired under sustained load"
        assert_operator result.fetch("p99_ms"), :<, 250
        if count >= 100
          runs[0].stop(force: true)
          assert_predicate claims[0][0].realtime(claim_token: claims[0][1]), :closed?
          claims[1][0].extend(claim_token: claims[1][1], timeout_ms: 1000)
          await(seconds: 5) { claims[1][0].realtime(claim_token: claims[1][1]).closed? }
          CybrosAgent::DeviceFlow::Client.new(base_url: server.base_url).revoke(token: claims[20][2])
          assert_predicate claims[20][0].realtime(claim_token: claims[20][1]), :closed?
          assert_predicate claims[99][0].realtime(claim_token: claims[99][1]), :active?
          puts "PASS: after 100-session load, Stop, timeout and original-member revoke close permission; unrelated session remains active"
        end
      end
      failed = result.fetch("errors").values.sum.positive? || result.fetch("p99_ms") >= 500 ||
        result.fetch("permission_gaps").fdiv([result.fetch("requests"), 1].max) >= 0.01
      break if failed
    end
  ensure
    FileUtils.rm_f(input) if input
    begin
      server&.preserve_log(File.join(output, "nexus-server-#{Time.now.to_i}.log")) if output && server
    ensure
      begin
        E2E.shutdown
      ensure
        server&.stop
        ENV.delete("E2E_BASE_URL")
        ENV.delete("E2E_NEXUS_OPERATOR")
      end
    end
  end

  private

    def issue_realtime_key(http, session, key_path)
      value = super
      @runner_key = value if key_path.end_with?("/executor/api_keys")
      value
    end
end
