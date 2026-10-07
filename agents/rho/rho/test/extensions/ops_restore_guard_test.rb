require "test_helper"
require_relative "../support/ops_harness"

class OpsRestoreGuardTest < Minitest::Test
  include RhoTest::OpsHarness

  RUNNER = RhoTest::DaemonHarness::RUNNER_IDENTITY.runner_executor_public_id

  # The API double still authors and starts the SDK's request run. Its
  # task read runs the real checkpoint tool against the daemon's stores.
  class RestoreApi < NexusDoubles::FakeAgentApi
    attr_accessor :tool_env
    attr_reader :restores

    def initialize(**options)
      super
      @restores = []
    end

    def run_response(method, path, credential, body = nil)
      return super unless method == :get && path.end_with?("/tasks/call_tool") && @tool_env

      tool = run_creates.last.fetch("run").fetch("steps").first.fetch("tool")
      handler = tool.fetch("name") == "checkpoints" ? Rho::Runner::Tools::Checkpoints : Rho::Runner::Tools::CheckpointRestore
      @restores << tool if tool.fetch("name") == "checkpoint_restore"
      result = handler.new(env: @tool_env).call(tool.fetch("input"))
      respond(200, { "task" => {
        "key" => "call_tool", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => tool.fetch("name"),
        "on_failure" => "propagate", "visibility" => "visible", "result" => { "is_error" => result.is_error },
        "output" => result.content, "structured_content" => result.structured_content, "metadata" => result.metadata,
        "created_at" => "2026-09-15T00:00:00Z",
      } })
    end
  end

  def setup
    super
    @projects = File.realpath(Dir.mktmpdir("rho-restore-roots"))
    @old_root, @current_root, @unrelated_root = %w[old current unrelated].map { |name| File.join(@projects, name) }
    FileUtils.mkdir_p([@old_root, @current_root, @unrelated_root])
    File.write(File.join(@old_root, "data.txt"), "before")
  end

  def teardown
    super
    FileUtils.remove_entry(@projects)
  end

  def prepare(runner: RUNNER, cached: true, store_id: nil)
    @daemon = boot
    @store = Rho::Runner::Checkpoints::Store.open(
      dir: File.join(@daemon.home.work_root, Rho::Runner::Checkpoints::Store::DIRECTORY), root: @old_root)
    @target = @store.capture(run_public_id: "L1")
    File.write(File.join(@old_root, "data.txt"), "after")
    effect = { "run_public_id" => "L1", "task_key" => "write", "runner_executor_public_id" => runner }
    effect["checkpoint"] = @target.key.merge("store" => store_id || @target.store) if cached
    effects = { "status" => "touched", "runners" => [effect] }
    turn = { "public_id" => "t0", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
             "status" => "completed", "visibility" => "visible", "created_at" => "2026-09-15T00:00:00Z",
             "answering_user_public_id" => "0199-user" }
    variants = { "turn" => { "public_id" => "t0" }, "variants" => [{ "public_id" => "v0",
      "source" => "run", "status" => "completed", "active" => true, "run_public_id" => "L1", "runner_effects" => effects }] }
    @api = RestoreApi.new(turns: [turn], fork_runner_effects: effects, conversation_runner: runner, variants: variants)
    @api.set_default_runner("c-1", runner)
    member_ready(@daemon, @api, identity: RhoTest::DaemonHarness::RUNNER_IDENTITY)
    @daemon.context.environments.receive("c-1", Rho::Runner::Environment::Binding.new(
      root: @current_root, directories: [], anchor: "c-1"))
    @api.tool_env = Rho::Runner::ToolEnv.new(root: @current_root, artifacts_dir: File.join(@projects, "artifacts"),
      checkpoint_resolver: @daemon.context.environments.method(:checkpoint_stores).to_proc)
  end

  def process_in(root)
    @daemon.host.processes.start(command: "sleep 30", workdir: root, env: Rho::Runner::ChildEnv.call,
      name: "server", run_public_id: "L1", conversation: "c-1")
  end

  def rewind(**options)
    response = request(@daemon, :post, "/conversations/rewind", token: bearer(@daemon),
      body: { "public_id" => "c-1", "turn" => "t0", **options })
    assert_equal "200", response.code, response.body
    JSON.parse(response.body).fetch("rewind")
  end

  def assert_old_root_protected
    process = process_in(@old_root)
    answer = rewind

    assert_equal "c-1-side", answer.fetch("conversation"), "the fork exists even when the local restore policy refuses"
    assert_equal({ "status" => "failed", "reason" => "process_live" }, answer.fetch("restoration").fetch("runners").first.except("runner_executor_public_id"))
    assert_empty @api.restores
    assert_equal "after", File.read(File.join(@old_root, "data.txt"))
    assert_predicate process, :live?
  end

  def test_rewind_checks_the_historical_checkpoint_root_after_the_conversation_moved
    prepare
    assert_old_root_protected
  end

  def test_rewind_checks_the_root_found_by_the_checkpoint_cache_miss
    prepare(cached: false)
    assert_old_root_protected
    assert_equal ["checkpoints"], @api.run_creates.map { |row| row.dig("run", "steps", 0, "tool", "name") }
  end

  def test_a_process_in_an_unrelated_root_does_not_block_the_restore
    prepare
    process = process_in(@unrelated_root)

    assert_equal "restored", rewind.dig("restoration", "status")
    assert_equal "before", File.read(File.join(@old_root, "data.txt"))
    assert_predicate process, :live?
    assert_equal 1, @api.restores.length
  end

  def test_a_remote_runner_does_not_consult_this_daemons_process_table
    prepare(runner: "remote-runner")
    process_in(@old_root)

    assert_equal "restored", rewind.dig("restoration", "status")
    assert_equal 1, @api.restores.length
  end

  def test_keep_checkpoints_does_not_check_the_historical_root
    prepare
    process_in(@old_root)

    assert_equal "kept", rewind(keep_checkpoints: true).dig("restoration", "status")
    assert_empty @api.run_creates
    assert_equal "after", File.read(File.join(@old_root, "data.txt"))
  end

  def test_an_unknown_store_keeps_the_restore_tools_own_failure
    prepare(store_id: "0" * 16)
    process_in(@old_root)

    assert_equal({ "status" => "failed", "reason" => "checkpoint_store_unknown" }, rewind.fetch("restoration").fetch("runners").first.except("runner_executor_public_id"))
    assert_equal 1, @api.restores.length
    assert_equal "after", File.read(File.join(@old_root, "data.txt"))
  end

  def test_the_current_root_process_guard_still_refuses_before_forking
    prepare
    process_in(@current_root)
    response = request(@daemon, :post, "/conversations/rewind", token: bearer(@daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    assert_equal "409", response.code
    assert_equal "process_live", JSON.parse(response.body).dig("error", "code")
    assert_empty @api.forks
  end

  def test_regenerate_does_not_open_the_door_when_the_historical_root_has_a_process
    prepare
    process_in(@old_root)
    response = request(@daemon, :post, "/conversations/regenerate", token: bearer(@daemon),
      body: { "idempotency_key" => "regenerate-test", "public_id" => "c-1", "turn" => "t0" })

    assert_equal "409", response.code, response.body
    assert_equal "restore_failed", JSON.parse(response.body).dig("error", "code")
    assert_equal "process_live", JSON.parse(response.body).dig("error", "restoration", "runners", 0, "reason")
    assert_empty @api.restores
    assert_empty @api.regenerations
    assert_equal "after", File.read(File.join(@old_root, "data.txt"))
  end
end
