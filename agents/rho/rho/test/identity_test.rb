require "test_helper"

# The paired mode in the pointer: a pointer of format 4 names
# the mode it was paired in and the runner it registered, so a boot whose
# settings disagree fails closed, and a runner-mode home files itself under
# a runner root rather than a user's.
class IdentityTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-identity")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_the_two_runner_identifiers_are_product_constants
    assert_equal "rho", Rho::RUNNER_IDENTIFIER, "full mode's in-process runner, named for the agent"
    assert_equal "rho-runner", Rho::STANDALONE_RUNNER_IDENTIFIER, "runner mode"
    assert_equal 4, Rho::Identity::SESSION_VERSION
  end

  def test_an_agent_identity_carries_its_mode_and_its_runner
    identity = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-executor",
      mode: "full", runner_executor_public_id: "0199-runner")

    assert_equal "full", identity.mode
    assert_equal "0199-runner", identity.runner_executor_public_id
    assert_equal({ "version" => 4, "mode" => "full", "user_public_id" => "0199-user",
                   "executor_public_id" => "0199-executor", "runner_executor_public_id" => "0199-runner" },
      identity.pointer_document)
    assert_equal @home.identity_root("0199-user"), identity.root
    assert_equal File.join(identity.root, "runner_credentials.json"), identity.runner_vault.path
    assert_equal @home.identity_work_root("0199-user"), identity.work_root

    agent_only = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-executor",
      mode: "agent")
    assert_equal %w[executor_public_id mode user_public_id version], agent_only.pointer_document.keys.sort,
      "compacted: an agent-mode pointer names no runner"
  end

  def test_a_runner_identity_has_no_user_and_lives_under_the_runner_root
    identity = Rho::Identity.runner(home: @home, executor_public_id: "0199-runner")

    assert_equal "runner", identity.mode
    assert_nil identity.user_public_id
    assert_equal "0199-runner", identity.executor_public_id
    assert_equal "0199-runner", identity.runner_executor_public_id
    assert_equal "0199-runner", identity.public_id
    assert_equal @home.runner_identity_root("0199-runner"), identity.root
    assert_equal File.join(@root, "runners", "0199-runner"), identity.root
    assert_equal({ "version" => 4, "mode" => "runner", "executor_public_id" => "0199-runner",
                   "runner_executor_public_id" => "0199-runner" }, identity.pointer_document)
    assert_equal @home.runner_work_root("0199-runner"), identity.work_root
  end

  def test_from_pointer_dispatches_on_the_mode_and_refuses_the_old_format
    runner = Rho::Identity.from_pointer(home: @home,
      pointer: { "version" => 4, "mode" => "runner", "executor_public_id" => "0199-runner",
                 "runner_executor_public_id" => "0199-runner" })
    assert_equal "runner", runner.mode
    assert_nil runner.user_public_id

    full = Rho::Identity.from_pointer(home: @home,
      pointer: { "version" => 4, "mode" => "full", "user_public_id" => "0199-user",
                 "executor_public_id" => "0199-executor", "runner_executor_public_id" => "0199-runner" })
    assert_equal "0199-runner", full.runner_executor_public_id

    error = assert_raises(Rho::StoredConnectionError) do
      Rho::Identity.from_pointer(home: @home,
        pointer: { "version" => 3, "user_public_id" => "0199-user", "executor_public_id" => "0199-executor" })
    end
    assert_match(/format version 4/, error.message, "no compat before release: refused, never read with a fallback")
    error = assert_raises(Rho::StoredConnectionError) do
      Rho::Identity.from_pointer(home: @home,
        pointer: { "version" => 4, "user_public_id" => "0199-user", "executor_public_id" => "0199-executor" })
    end
    assert_match(/mode/, error.message, "a version-4 pointer names its mode")
  end

  def test_the_session_records_the_mode_and_a_mode_change_fails_closed
    clock = -> { Time.utc(2026, 9, 7) }
    identity = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-executor",
      mode: "full", runner_executor_public_id: "0199-runner").prepare.record(clock: clock)

    assert_equal "full", identity.session.read.fetch("mode")
    assert_equal "0199-runner", identity.session.read.fetch("runner_executor_public_id")
    identity.verify_belongs_here

    changed = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-executor",
      mode: "agent")
    error = assert_raises(Rho::StoredConnectionError) { changed.verify_belongs_here }
    assert_match(/pointer's mode/, error.message)
  end

  def test_with_runner_and_without_runner_rewrite_the_mode_with_the_runner
    agent = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-executor",
      mode: "agent")

    full = agent.with_runner("0199-runner")
    assert_equal %w[full 0199-runner], [full.mode, full.runner_executor_public_id]
    assert_equal agent.root, full.root
    back = full.without_runner
    assert_equal "agent", back.mode
    assert_nil back.runner_executor_public_id
  end
end
