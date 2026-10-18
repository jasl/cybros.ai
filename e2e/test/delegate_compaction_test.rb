require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/compaction_results"
require "support/executor_process"
require "support/peer_program"
require "support/runner_grant"
require "support/steward_session"
require "support/thread_check"

# A generic declaration delegates compaction to an independent executor.
# The submitter exits at acceptance. A dead delegate times out naturally and
# Nexus supplies one kernel summary while the coding Runner stays online.
class DelegateCompactionTest < Minitest::Test
  include E2E::ThreadCheck
  include E2E::CompactionResults
  MODEL = "dev/mock-text".freeze
  REREAD_RULE = "This summary replaces earlier history and carries no data values: " \
    "re-read any file, output or result it mentions before you use it.".freeze
  COMPACTION_HEADER = "Here is the transcript to compact.".freeze

  def setup
    @base_url = E2E.base_url
    human = E2E::ActorProvisioning.world(@base_url).rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: human)
    @peer = E2E::PeerProgram.pair(base_url: @base_url, actor: @actor, name: "compaction")
    @home = Dir.mktmpdir("e2e-compaction")
    @project = File.join(@home, "project").tap { |path| FileUtils.mkdir_p(path) }
    @runners = []
    @runs = []
    @coding = runner("coding", world: @project, environment: @project)
    delegate_home = File.join(@home, "delegate").tap { |path| FileUtils.mkdir_p(path) }
    @delegate = E2E::ExecutorProcess.new(base_url: @base_url, home: delegate_home,
      credential: @peer.executor_credential, kind: :agent_application, tools: E2E::CompactionTools.names).start
    @runners << @delegate
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @peer.client.workspace(@peer.client.workspaces.create(
      name: "Delegate compaction", idempotency_key: SecureRandom.uuid).workspace.public_id)
    @workspace_public_id = @workspace.public_id
  end

  def teardown
    @runs.each { |run| run.stop(force: true) if run.fetch.status == "running" }
    @runners.each { |process| warn E2E::SecretHygiene.redact(process.log_text) } unless passed?
  ensure
    @runners&.each(&:stop)
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_an_independent_delegate_summarizes_and_a_dead_delegate_falls_back_once
    verify_compaction("compact_history", fallback: false)
    verify_compaction("held_compaction", fallback: true)
  end

  private

    def verify_compaction(tool, fallback:)
      marker = "first-line-#{SecureRandom.hex(6)}"
      conversation, turn, loop = open_turn(tool, compaction_prompt(@project, marker))
      if fallback
        await("the independent delegate never claimed k1") { @delegate.claims.any? { |claim| claim["task"] == "k1" && claim["tool"] == tool } }
        @delegate.kill!
      end
      completed = await_run_status(loop, "completed")
      variant_id = loop_variant(conversation, turn, loop)
      tasks = completed.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
      assert_equal %w[completed completed], %w[r1 r2].map { |key| tasks.fetch(key).fetch("status") }
      delegate = tasks.fetch("k1")
      assert_equal ["tool_task", tool, fallback ? "timed_out" : "completed", "collapsed"],
        delegate.values_at("kind", "tool_name", "status", "visibility")
      assert_equal @delegate.executor_public_id, delegate.dig("claimed_by", "executor_public_id")
      assert_equal "agent_application", delegate.dig("addressed_to", "role")
      events = feed(conversation).select { |item| item["type"] == "context_compacted" }.map { |item| item.fetch("payload") }
      expected = { "mode" => "delegate", "trigger" => "usage", "task_key" => "r2", "summary_task_key" => "k1",
        "variant_public_id" => variant_id, "run_public_id" => loop, "turn_public_id" => turn }
      assert_equal expected, events.first

      summary_key = fallback ? "k2" : "k1"
      if fallback
        assert_equal "tool_timeout", delegate.dig("error", "key")
        assert_equal %w[model_task completed collapsed], tasks.fetch("k2").values_at("kind", "status", "visibility")
        assert_nil tasks["k3"], "only one fallback summary is appended"
        assert_equal expected.merge("mode" => "kernel", "trigger" => "fallback", "summary_task_key" => "k2",
          "fallback_from" => "k1", "fallback_reason" => "tool_timeout"), events.last
        assert_empty task_output(loop, "k1")
      end
      assert_equal fallback ? 2 : 1, events.size
      summary = task_output(loop, summary_key)
      assert_includes summary, fallback ? COMPACTION_HEADER : "Independent summary"
      assert_includes summary, "Tool bash (completed, ok)"
      assert_includes summary, "not carried"
      refute_includes summary, marker, "summaries carry pointers, not tool output values"
      continued = task_output(loop, "r2")
      assert_includes continued, REREAD_RULE
      assert_includes continued, fallback ? COMPACTION_HEADER : "Independent summary"
      assert_equal 1, continued.scan(marker).length
      assert_compaction_result_request(loop, marker)
      thread = assert_thread_matches_graph!(loop)
      refute_includes thread.fetch("mainline").flat_map { |row| row["calls"] }, summary_key
      assert_empty thread.fetch("branches")
      repaired = agent_api("#{loop_path(loop)}/transcript").fetch("rounds").find { |row| row["task_key"] == "r2" }
      assert_equal "r2", repaired.fetch("compacted_before")
    end

    def runner(name, **options)
      device = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = device.request_runner_authorization(registration_identifier: "e2e-compaction-#{name}-#{SecureRandom.hex(4)}",
        runner_display_name: "Compaction #{name}")
      E2E::RunnerGrant.visit_connection(actor: @actor, authorization: authorization)
      E2E::RunnerGrant.connect_in_browser(actor: @actor, authorization: authorization)
      credentials = device.await_credentials(authorization)
      home = File.join(@home, name).tap { |path| FileUtils.mkdir_p(path) }
      process = E2E::ExecutorProcess.new(base_url: @base_url, home: home,
        credential: credentials.executor_access_token, **options).start
      @runners << process
      process
    end

    def open_turn(tool, prompt)
      declaration = { "default_model" => MODEL, "prompt_mechanism" => "default", "approval_mode" => "bypass",
        "tool_definitions" => [], "runner_executor_public_ids" => [@coding.executor_public_id],
        "runner_tool_names" => ["bash"], "compaction_policy" => { "mode" => "delegate", "tool_name" => tool, "model" => MODEL } }
      chat = @workspace.conversation(@workspace.conversations.create(default_runner_executor_public_id: @coding.executor_public_id,
        memory_context: { "bindings" => [] }, idempotency_key: SecureRandom.uuid).public_id)
      receipt = @peer.submit_and_exit(base_url: @base_url, workspace_public_id: @workspace_public_id,
        conversation_public_id: chat.public_id, kind: "direct_reply", text: prompt, model: MODEL,
        agent_configuration: declaration, idempotency_key: SecureRandom.uuid)
      materialization = await("the input to materialize") { chat.inputs.materialization(receipt) }
      @runs << @workspace.run(materialization.run_public_id)
      [chat.public_id, materialization.turn_public_id, materialization.run_public_id]
    end

    LOOP_POLL = 1
    AWAIT_SECONDS = 120

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_output(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").dig("task", "output").to_s

    def loop_variant(conversation, turn, loop)
      path = "/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/turns/#{turn}/variants"
      agent_api(path).fetch("variants").find { |variant| variant["run_public_id"] == loop }.fetch("public_id")
    end

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def await_run_status(loop, status)
      await("the loop never reached #{status}", every: LOOP_POLL) do
        row = loop_row(loop)
        row if row["status"] == status
      end
    end

    def await(message, every: 0.5)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    # The MEMBER plane, as the person who owns the work. UTF-8 by name.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@peer.credential}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end
end
