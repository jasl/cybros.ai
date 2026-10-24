require "test_helper"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "zlib"
require "support/actor_provisioning"
require "support/ceremony"
require "support/sdk_process"
require "support/secret_hygiene"
require "support/steward_session"

class StandaloneSDKAgentTest < Minitest::Test
  def setup
    E2E::SDKProcess.prepare!
    @base_url = E2E.base_url
    @steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    @human = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @home = Dir.mktmpdir("standalone-sdk-agent")
    @credentials_path = File.join(@home, "credentials.json")
    E2E.enable_dev_lane!
    E2E.hosts.start
    E2E::SessionSignInBudget.consume
    grant = CybrosAgent::Platform::Sessions.new(base_url: @base_url)
      .create(email: @steward.email, password: @steward.password)
    @platform = CybrosAgent::PlatformClient.new(base_url: @base_url,
      credential: E2E::SecretHygiene.register(grant.token))
  end

  def teardown
    if @workspace_id
      workspace = @human.workspace(@workspace_id)
      workspace.runs.list.items.each do |run|
        workspace.run(run.public_id).stop(force: true) unless run.terminal?
      end
      workspace.delete(lock_version: @human.workspaces.fetch(@workspace_id).lock_version)
    end
    @platform&.agents&.agent(@agent_id)&.remove if @agent_id
  ensure
    @platform&.session&.revoke
    FileUtils.remove_entry(@home) if @home
  end

  def test_standalone_cli_connects_exits_and_recovers_its_original_execution_and_files
    E2E::DeviceAuthorizationBudget.consume
    connected, = run_example("connect", "--agent-identifier", "standalone-#{SecureRandom.hex(6)}") do |process|
      authorization = process.wait_for("authorization")
      E2E::Ceremony.confirm(actor: @actor, started: authorization.merge("branch" => "agent"))
    end
    assert_equal "connected", connected.fetch("event")
    @agent_id = connected.fetch("agent_public_id")
    executor_id = connected.fetch("executor_public_id")

    text = "!mock reply=standalone-complete usage=2:1 -- standalone-#{SecureRandom.hex(6)}"
    accepted, facts = run_example("start", "--model", "dev/mock-priced", "--text", text, "--submit-only")
    assert_equal "accepted", accepted.fetch("event")
    refute facts.any? { |fact| fact["event"] == "tool_completed" }
    @workspace_id = accepted.fetch("workspace_public_id")
    chat = @human.workspace(@workspace_id).conversation(accepted.fetch("conversation_public_id"))
    original = await("the accepted Input did not materialize after the CLI exited") do
      chat.inputs.materialization(accepted.fetch("input_public_id"))
    end
    run = @human.workspace(@workspace_id).run(original.run_public_id)
    waiting = await("the application tool did not become available after process exit") do
      candidate = run.fetch.tasks.find { |task| task.key == "capture_text" }
      candidate if candidate && candidate.status != "waiting"
    end
    refute waiting.terminal?
    assert_nil waiting.claimed_by
    assert_equal executor_id, waiting.addressed_to.executor_public_id
    assert_equal "0.0000025", chat.fetch.usage_summary.cost_amount

    resume = ["--workspace", @workspace_id, "--conversation", chat.public_id,
      "--input", accepted.fetch("input_public_id")]
    completed, resumed_facts = run_example("resume", *resume, "--output-dir", File.join(@home, "first"))
    assert_completed_files(completed, original, text)
    tool_facts = resumed_facts.select { |fact| fact["event"] == "tool_completed" }
    assert_equal 1, tool_facts.size
    assert_equal completed.fetch("upload_public_id"), tool_facts.first.fetch("upload_public_id")
    assert_equal "completed", run.fetch.status
    assert_equal executor_id, run.task("capture_text").task.claimed_by.executor_public_id

    original_tasks = run.fetch.tasks.map(&:key)
    original_receipts = exported_records(completed.fetch("export_path"))
      .filter_map { |record| record.fetch("usage").fetch("usage_record_public_id") if record["type"] == "usage" }
    recovered, recovered_facts = run_example("resume", *resume, "--output-dir", File.join(@home, "second"))
    assert_completed_files(recovered, original, text)
    refute recovered_facts.any? { |fact| fact["event"] == "tool_completed" },
      "a completed execution is read without claiming another tool"
    assert_equal completed.fetch("upload_public_id"), recovered.fetch("upload_public_id")
    assert_equal original_tasks, run.fetch.tasks.map(&:key)
    assert_equal original_receipts, exported_records(recovered.fetch("export_path"))
      .filter_map { |record| record.fetch("usage").fetch("usage_record_public_id") if record["type"] == "usage" }
    assert_equal [original.run_public_id], @human.workspace(@workspace_id).runs.list.items.map(&:public_id)
    assert_equal 1, chat.turns.list.items.count { |turn| turn.input_public_id == accepted.fetch("input_public_id") }
  end

  private

    def run_example(command, *arguments)
      sdk = File.expand_path("../../../sdks/typescript", __dir__)
      process = E2E::SDKProcess.new(
        ["pnpm", "--dir", sdk, "exec", "tsx", "examples/standalone-agent.ts", command,
          "--url", @base_url, "--credentials", @credentials_path, "--timeout-ms", "60000", *arguments],
        {}, timeout: 90
      )
      yield process if block_given?
      [process.finish, process.records]
    ensure
      process&.close
    end

    def assert_completed_files(result, original, text)
      assert_equal "completed", result.fetch("event")
      assert_equal original.turn_public_id, result.fetch("turn_public_id")
      assert_equal original.variant_public_id, result.fetch("variant_public_id")
      assert_equal original.run_public_id, result.fetch("run_public_id")
      assert_equal "capture_text", result.fetch("task_key")
      assert_equal text, File.binread(result.fetch("capture_path")).force_encoding(Encoding::UTF_8)
      records = exported_records(result.fetch("export_path"))
      assert_equal "export", records.first.fetch("type")
      assert_equal "end", records.last.fetch("type")
      assert_equal records.group_by { |record| record.fetch("type") }.transform_values(&:size), records.last.fetch("counts")
      task = records.find do |record|
        record["type"] == "task" && record.fetch("run_public_id") == original.run_public_id && record.fetch("task").fetch("key") == "capture_text"
      end
      refute_nil task
      assert_equal({ "text" => text }, task.fetch("task").fetch("structured_content"))
      assert_includes JSON.generate(task.fetch("task").fetch("content")), result.fetch("upload_public_id")
      usages = records.filter_map { |record| record.fetch("usage") if record["type"] == "usage" }
      assert_equal 1, usages.size
      assert_equal "0.0000025", usages.first.fetch("cost_amount")
      assert_equal 3, usages.first.fetch("total_tokens")
    end

    def exported_records(path)
      Zlib::GzipReader.open(path) { |gzip| gzip.each_line.map { |line| JSON.parse(line) } }
    end

    def await(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      loop do
        value = yield
        return value if value
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.1
      end
    end
end
