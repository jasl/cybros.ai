require "test_helper"

# ONE OBJECT, THREE PLANES: the SDK's OAuth is one refresh lineage, and a combined
# consume mints two — so the daemon's `about` is this holder, keyed by its identity,
# with the runner lineage in a slot a restore keeps and a loss drops without moving the
# agent's.
class CredentialsTest < Minitest::Test
  MEMBER = NexusDoubles::MEMBER_TOKEN
  TRANSPORT = NexusDoubles::TRANSPORT_TOKEN
  RUNNER = NexusDoubles::RUNNER_TOKEN

  def setup
    @root = Dir.mktmpdir("rho-credentials")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def lineage(name, access_token:, executor_access_token:)
    CybrosAgent::Credentials::OAuth.issue(
      credentials: CybrosAgent::DeviceFlow::Credentials.new(
        access_token: access_token, executor_access_token: executor_access_token,
        refresh_token: "rt-#{name}", token_type: "Bearer", expires_in: 1_209_600
      ),
      authority: nil, store: Rho::StateFile.new(File.join(@root, "#{name}.json")), clock: -> { Time.now }
    )
  end

  def agent = lineage("agent", access_token: MEMBER, executor_access_token: TRANSPORT)
  def runner = lineage("runner", access_token: nil, executor_access_token: RUNNER)

  def test_a_full_holder_answers_every_plane_from_its_own_lineage
    about = Rho::Credentials.new(agent: agent, runner: runner)

    assert_equal MEMBER, about.member_credential
    assert_equal TRANSPORT, about.executor_credential
    assert_equal RUNNER, about.runner_credential
    assert about.agent?
    assert about.runner?
    assert_equal [about.agent, about.runner], about.lineages
    assert_equal 0, about.rotation(:member)
    assert_equal 0, about.rotation(:runner_transport)
    assert_equal({ agent: MEMBER, runner: RUNNER }, { agent: about.member_credential, runner: about.runner_credential })
  end

  def test_an_absent_lineage_is_a_plane_unavailable_never_a_nil
    agent_only = Rho::Credentials.new(agent: agent)
    assert_raises(CybrosAgent::Credentials::PlaneUnavailable) { agent_only.runner_credential }
    refute agent_only.runner?
    assert_nil agent_only.rotation(:runner_transport)

    runner_only = Rho::Credentials.new(runner: runner)
    assert_raises(CybrosAgent::Credentials::PlaneUnavailable) { runner_only.member_credential }
    assert_raises(CybrosAgent::Credentials::PlaneUnavailable) { runner_only.executor_credential }
    assert_equal RUNNER, runner_only.runner_credential
    refute runner_only.agent?
    assert_equal [runner_only.runner], runner_only.lineages
  end

  # The slot writers are pure (no IO) so the lineage may run them under its
  # monitor; the holder's identity is what every daemon edge keys on, and it
  # never changes when the runner half does.
  def test_attach_and_drop_move_the_runner_slot_and_keep_the_holders_identity
    about = Rho::Credentials.new(agent: agent)
    attached = runner

    assert_same about, about.attach_runner(attached)
    assert_same attached, about.runner
    assert_equal RUNNER, about.runner_credential
    assert_same attached, about.drop_runner
    refute about.runner?
    assert_nil about.drop_runner, "dropping twice drops nothing"
  end

  def test_no_diagnostic_renders_a_credential
    about = Rho::Credentials.new(agent: agent, runner: runner)
    [about.inspect, about.to_s].each do |diagnostic|
      refute_includes diagnostic, "secret"
      assert_includes diagnostic, "runner"
    end
  end
end
