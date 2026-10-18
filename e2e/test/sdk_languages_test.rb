require "test_helper"
require "securerandom"
require "stringio"
require "bigdecimal"
require "zlib"
require "support/actor_provisioning"
require "support/ceremony"
require "support/sdk_process"
require "support/secret_hygiene"
require "support/steward_session"

# Independent processes exercise the packaged SDKs against one real Nexus.
# Ruby provisions and verifies through its public API; Member and Executor
# work cross the TypeScript/Rust boundary in both directions.
class SDKLanguagesTest < Minitest::Test
  def setup
    E2E::SDKProcess.prepare!
    @base_url = E2E.base_url
    @steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    @human = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    E2E::SessionSignInBudget.consume
    grant = CybrosAgent::Platform::Sessions.new(base_url: @base_url)
      .create(email: @steward.email, password: @steward.password)
    @platform = CybrosAgent::PlatformClient.new(base_url: @base_url,
      credential: E2E::SecretHygiene.register(grant.token))
    @agent = @platform.agents.create(display_name: "Cross-language SDK #{SecureRandom.hex(4)}")
    @agent_context = @platform.agents.agent(@agent.public_id)
    @runner = @agent_context.private_runners.create(display_name: "Cross-language Runner")
    @revocations = []
    @member_key = issue_key(@agent_context.api_keys, "Member")
    @application_key = issue_key(@agent_context.executor_api_keys, "Application")
    @runner_key = issue_key(@agent_context.private_runners.runner(@runner.public_id).api_keys, "Runner")
    @member = CybrosAgent::Client.new(base_url: @base_url, credential: @member_key)
    @application = CybrosAgent::ExecutorClient.new(base_url: @base_url, credential: @application_key)
    @application_address = @application.executor.executor
    @executor = CybrosAgent::ExecutorClient.new(base_url: @base_url, credential: @runner_key)
    @workspaces = []
  end

  def teardown
    @workspaces&.each do |workspace_id|
      @member.workspace(workspace_id).runs.list.items.each do |run|
        @member.workspace(workspace_id).run(run.public_id).stop(force: true) unless run.terminal?
      end
      current = @human.workspaces.fetch(workspace_id)
      @human.workspace(workspace_id).delete(lock_version: current.lock_version)
    end
    @revocations&.each { |resource, public_id| resource.revoke(public_id) }
    @agent_context&.remove
  ensure
    @platform&.session&.revoke
  end

  def test_typescript_member_with_rust_executor_replays_and_recovers
    exercise_languages(member_language: :typescript, executor_language: :rust)
  end

  def test_rust_member_with_typescript_executor_replays_and_recovers
    exercise_languages(member_language: :rust, executor_language: :typescript)
  end

  private

    def exercise_languages(member_language:, executor_language:)
      assert_language_authentication(member_language)
      announced = drive(executor_language, "executor_announce", credential: @runner_key)
      assert_equal @runner.public_id, announced.fetch("executor_public_id")

      marker = "#{member_language}-to-#{executor_language}-#{SecureRandom.hex(6)}"
      prepared = prepare_input(member_language, marker)
      original = await_materialization(prepared)
      await_task(original.run_public_id)
      completed = nil
      followed = drive(member_language, "member_follow", **input_arguments(prepared)) do |child|
        child.wait_for("ready")
        E2E.disconnect_cable!(@agent.public_id)
        child.wait_for("reconnected")
        completed = drive(executor_language, "executor_complete", credential: @runner_key,
          run_public_id: original.run_public_id, task_key: "sdk_echo", marker:)
      end
      assert_equal original.run_public_id, completed.fetch("run_public_id")
      assert_equal "sdk_echo", completed.fetch("task_key")
      assert_execution(original, followed, marker)
      assert_equal "completed", followed.fetch("run_status")

      bytes = StringIO.new
      @member.uploads.bytes(completed.fetch("upload_public_id"), bytes)
      assert_equal "capture:#{marker}", bytes.string
      task = @member.workspace(prepared.fetch("workspace_public_id")).run(original.run_public_id).task("sdk_echo")
      assert_equal({ "marker" => marker }, task.structured_content)
      assert_diagnostic_export(prepared, original, completed, marker)

      position = followed.fetch("position")
      assert_operator position.fetch("sequence"), :>, 0
      refute_empty position.fetch("cursor")
      sequences = followed.fetch("sequences")
      assert_equal sequences.sort.uniq, sequences
      workspace = @member.workspace(prepared.fetch("workspace_public_id"))
      run_ids = workspace.runs.list.items.map(&:public_id)
      recovered = drive(member_language, "member_observe", **input_arguments(prepared), position:)
      assert_execution(original, recovered, marker)
      assert_equal run_ids, workspace.runs.list.items.map(&:public_id), "recovery must not create a replacement Run"

      canceled_input = prepare_input(member_language, "cancel-#{marker}")
      canceled_original = await_materialization(canceled_input)
      await_task(canceled_original.run_public_id)
      canceled = drive(member_language, "member_cancel", **input_arguments(canceled_input))
      assert_equal canceled_original.run_public_id, canceled.fetch("run_public_id")
      assert_equal "canceled", canceled.fetch("run_status")
      assert_equal "canceled", @member.workspace(canceled_input.fetch("workspace_public_id"))
        .run(canceled_original.run_public_id).fetch.status
    end

    def assert_language_authentication(language)
      E2E::SessionSignInBudget.consume
      managed = drive(language, "platform_smoke", email: @steward.email, password: @steward.password,
        marker: "#{language}-#{SecureRandom.hex(4)}")
      assert_equal @steward.public_id, managed.fetch("human_public_id")
      assert managed.fetch("removed")
      refute_empty managed.fetch("agent_public_id")

      actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
      E2E::DeviceAuthorizationBudget.consume
      logged_in = drive(language, "application_login", agent_identifier: @agent.agent_identifier,
        marker: "#{language} login") do |child|
        authorization = child.wait_for("authorization")
        E2E::Ceremony.confirm(actor:, started: authorization.merge("branch" => "login", "mode" => "agent"))
      end
      assert_equal @steward.public_id, logged_in.fetch("human_public_id")
      refute logged_in.fetch("has_agent_credentials")
      refute logged_in.fetch("has_runner_credentials")
      assert logged_in.fetch("refresh_rotated")
      assert logged_in.fetch("revoked")
      assert_equal @agent.public_id, @member.profile.fetch.member.public_id,
        "Human login and logout preserve the existing Agent credential"
      current_address = @application.executor.executor
      assert_equal @application_address.public_id, current_address.public_id
      assert_equal @application_address.credential_epoch, current_address.credential_epoch,
        "Human login and logout preserve the application address and epoch"
    end

    def issue_key(resource, name)
      grant = resource.create(name:)
      @revocations << [resource, grant.api_key.public_id]
      E2E::SecretHygiene.register(grant.secret)
    end

    def prepare_input(language, marker)
      drive(language, "member_prepare", credential: @member_key,
        runner_public_id: @runner.public_id, marker:, workspace_key: SecureRandom.uuid_v7,
        conversation_key: SecureRandom.uuid_v7, input_key: SecureRandom.uuid_v7).tap do |result|
        @workspaces << result.fetch("workspace_public_id")
      end
    end

    def input_arguments(prepared)
      { credential: @member_key, workspace_public_id: prepared.fetch("workspace_public_id"),
        conversation_public_id: prepared.fetch("conversation_public_id"), input_public_id: prepared.fetch("input_public_id") }
    end

    def await_materialization(prepared)
      inputs = @member.workspace(prepared.fetch("workspace_public_id"))
        .conversation(prepared.fetch("conversation_public_id")).inputs
      input_id = prepared.fetch("input_public_id")
      await("the exact Input did not materialize") do
        result = inputs.materialization(input_id)
        unless result
          input = inputs.list.find { |candidate| candidate.public_id == input_id }
          flunk "the exact Input is blocked: #{input.blocked_reason}" if input&.blocked?
        end
        result
      end
    end

    def await_task(run_id)
      await("the trailing tool did not reach the Runner inbox") do
        @executor.inbox.list.items.find { |task| task.run_public_id == run_id && task.task_key == "sdk_echo" }
      end
    end

    def assert_execution(original, result, marker)
      assert_equal original.turn_public_id, result.fetch("turn_public_id")
      assert_equal original.variant_public_id, result.fetch("variant_public_id")
      assert_equal original.run_public_id, result.fetch("run_public_id")
      assert_equal "completed", result.fetch("status")
      assert_includes result.fetch("final_text"), marker
    end

    def assert_diagnostic_export(prepared, original, completed, marker)
      workspace_id = prepared.fetch("workspace_public_id")
      conversation_id = prepared.fetch("conversation_public_id")
      chat = @member.workspace(workspace_id).conversation(conversation_id)
      bytes = StringIO.new
      response = chat.export(bytes)
      assert_equal 200, response.status
      records = Zlib::GzipReader.wrap(StringIO.new(bytes.string)) do |gzip|
        gzip.each_line.map { |line| JSON.parse(line) }
      end
      assert_equal "export", records.first.fetch("type")
      assert_equal "end", records.last.fetch("type")
      assert_equal records.group_by { |row| row.fetch("type") }.transform_values(&:size), records.last.fetch("counts")
      assert records.all? { |record| record.fetch("conversation_public_id") == conversation_id }
      turn = records.find { |row| row["type"] == "turn" && row.fetch("turn").fetch("public_id") == original.turn_public_id }
      refute_nil turn
      assert_equal prepared.fetch("input_public_id"), turn.fetch("turn").fetch("input_public_id")
      assert records.any? { |row| row["type"] == "variant" && row.fetch("variant").fetch("public_id") == original.variant_public_id }
      exported_task = records.find do |row|
        row["type"] == "task" && row.fetch("run_public_id") == original.run_public_id && row.fetch("task").fetch("key") == "sdk_echo"
      end
      refute_nil exported_task
      assert_equal({ "marker" => marker }, exported_task.fetch("task").fetch("structured_content"))
      assert_includes JSON.generate(exported_task.fetch("task").fetch("content")), completed.fetch("upload_public_id")
      assert records.any? { |row| row["type"] == "graph_node" && row.fetch("run_public_id") == original.run_public_id }
      assert records.any? { |row| row["type"] == "request" && row.fetch("run_public_id", nil) == original.run_public_id }
      usage = records.filter_map { |row| row.fetch("usage") if row["type"] == "usage" }
      summary = chat.fetch.usage_summary
      assert_equal summary.request_count, usage.size
      assert_equal BigDecimal(summary.cost_amount), usage.sum { |row| BigDecimal(row.fetch("cost_amount")) }
      assert_equal summary.total_tokens, usage.sum { |row| row.fetch("total_tokens", 0) }
      assert usage.all? { |row| row.fetch("cost_complete") }
      refute_empty records.select { |row| row["type"] == "event" }

      chat.set_access(default: "none")
      assert_equal workspace_id, @human.workspaces.fetch(workspace_id).public_id,
        "the excluded principal still reads the Workspace"
      denied = assert_raises(CybrosAgent::Api::NotFound) do
        @human.workspace(workspace_id).conversation(conversation_id).export(StringIO.new)
      end
      assert_equal "not_found", denied.code
      allowed = StringIO.new
      chat.export(allowed)
      refute_empty allowed.string, "the creator still exports the existing work"
    end

    def drive(language, action, **payload, &block)
      E2E::SDKProcess.run(language, { action:, base_url: @base_url, **payload }, &block)
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
