require "test_helper"

# Whether each plane is still accepted. The kernel answers 401 identically for
# a revoked, fenced, expired or wrong-plane credential, so this class may
# report that a plane stopped working and must never claim to know why.
class AuthorityTest < Minitest::Test
  MEMBER = NexusDoubles::MEMBER_TOKEN
  TRANSPORT = NexusDoubles::TRANSPORT_TOKEN
  RUNNER = NexusDoubles::RUNNER_TOKEN

  def setup
    @root = Dir.mktmpdir("rho-authority")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    @now = Time.utc(2026, 7, 26, 12, 0, 0)
    @api = NexusDoubles::SelectiveApi.new
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # `expires_in` defaults to a fresh 14-day credential — what a running daemon
  # actually holds — because that is the case where a refusal must NOT cost a
  # rotation. Tests of the repair path pass an expired one explicitly.
  # The daemon's `about` is the composite holder (Rho::Credentials): the
  # agent lineage, and in full mode the runner lineage beside it.
  def oauth(planes: %i[member executor], authority: rotating_authority, expires_in: 1_209_600, runner: nil)
    Rho::Credentials.new(agent: lineage(planes: planes, authority: authority, expires_in: expires_in), runner: runner)
  end

  def lineage(planes: %i[member executor], authority: rotating_authority, expires_in: 1_209_600, name: "vault")
    CybrosAgent::Credentials::OAuth.issue(
      credentials: CybrosAgent::DeviceFlow::Credentials.new(
        access_token: (MEMBER if planes.include?(:member)),
        executor_access_token: (TRANSPORT if planes.include?(:executor)),
        refresh_token: "rt-0", token_type: "Bearer", expires_in: expires_in
      ),
      authority: authority, store: Rho::StateFile.new(File.join(@root, "#{name}.json")),
      clock: -> { @now }
    )
  end

  def runner_lineage(authority: rotating_authority, expires_in: 1_209_600)
    CybrosAgent::Credentials::OAuth.issue(
      credentials: CybrosAgent::DeviceFlow::Credentials.new(
        access_token: nil, executor_access_token: RUNNER,
        refresh_token: "rt-r0", token_type: "Bearer", expires_in: expires_in
      ),
      authority: authority, store: Rho::StateFile.new(File.join(@root, "runner.json")),
      clock: -> { @now }
    )
  end

  def rotating_authority(rotated: nil, failure: nil)
    object = Object.new
    object.define_singleton_method(:rotate) do |refresh_token:|
      raise failure if failure

      rotated || CybrosAgent::DeviceFlow::Credentials.new(
        access_token: MEMBER, executor_access_token: TRANSPORT,
        refresh_token: "rt-next", token_type: "Bearer", expires_in: 1_209_600
      )
    end
    object
  end

  def authority_for(credentials, mode: "agent")
    Rho::Authority.new(oauth: credentials, base_url: @home.base_url, transport: @api, mode: mode)
  end

  def test_both_planes_live_is_the_ordinary_product_state
    report = authority_for(oauth).check

    assert_equal({ member: :live, executor_transport: :live }, report[:planes])
    refute report[:lost]
    refute report[:runner_lost]
  end

  # ---- the planes are the mode's ----

  def test_full_mode_asks_three_planes_and_a_missing_runner_lineage_is_absent
    report = authority_for(oauth(runner: runner_lineage), mode: "full").check
    assert_equal({ member: :live, executor_transport: :live, runner_transport: :live }, report[:planes])
    assert_includes @api.calls, ["/agent_api/v1/executor", RUNNER]

    report = authority_for(oauth, mode: "full").check
    assert_equal :absent, report[:planes][:runner_transport], "a full connection with no runner lineage"
    assert_equal :live, report[:planes][:member]
  end

  def test_a_dead_runner_plane_leaves_the_agent_planes_alone
    @api.accept(RUNNER, false)

    report = authority_for(oauth(runner: runner_lineage), mode: "full").check
    assert_equal :unauthorized, report[:planes][:runner_transport]
    assert_equal :live, report[:planes][:member]
    assert_equal :live, report[:planes][:executor_transport]
    refute report[:lost]
  end

  def test_runner_mode_asks_the_one_plane_and_its_loss_is_the_daemons
    lost = CybrosAgent::DeviceFlow::AuthorizationLostError.new(oauth_error: "invalid_grant")
    about = Rho::Credentials.new(runner: runner_lineage(authority: rotating_authority(failure: lost), expires_in: 0))
    @api.accept(RUNNER, false)

    report = authority_for(about, mode: "runner").check
    assert_equal [:runner_transport], report[:planes].keys
    assert report[:lost], "the one lineage IS the runner's"
    refute report[:runner_lost]
  end

  def test_a_terminally_lost_runner_lineage_beside_a_live_agent_is_runner_lost_never_lost
    lost = CybrosAgent::DeviceFlow::AuthorizationLostError.new(oauth_error: "invalid_grant")
    about = oauth(runner: runner_lineage(authority: rotating_authority(failure: lost), expires_in: 0))
    @api.accept(RUNNER, false)

    report = authority_for(about, mode: "full").check
    assert report[:runner_lost]
    refute report[:lost]
    assert_equal :unauthorized, report[:planes][:runner_transport]
    assert_equal :live, report[:planes][:member]
  end

  def test_the_expected_identity_names_the_runner_plane_by_its_own_public_id
    identity = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-executor",
      mode: "full", runner_executor_public_id: "0199-elsewhere")
    authority = Rho::Authority.new(oauth: oauth(runner: runner_lineage), base_url: @home.base_url,
      transport: @api, expected_identity: identity, mode: "full")

    error = assert_raises(Rho::StoredConnectionError) { authority.check }
    assert_match(/runner_transport credential names "0199-runner", expected "0199-elsewhere"/, error.message)
  end

  # The headline case Round D built: the member's authority died, and the
  # delivery address must keep working rather than being torn down with it.
  def test_a_dead_member_plane_leaves_the_transport_plane_alone
    @api.accept(MEMBER, false)

    report = authority_for(oauth).check
    assert_equal :unauthorized, report[:planes][:member]
    assert_equal :live, report[:planes][:executor_transport]
  end

  def test_the_reverse_is_equally_legal
    @api.accept(TRANSPORT, false)

    report = authority_for(oauth).check
    assert_equal :live, report[:planes][:member]
    assert_equal :unauthorized, report[:planes][:executor_transport]
  end

  # A soft-removal rotation may converge to an executor-only bundle. The
  # missing member plane is absence, not a fabricated refusal, and still makes
  # the Agent eligible for an explicit restore ceremony.
  def test_a_plane_this_connection_never_had_is_absent_not_unauthorized
    report = authority_for(oauth(planes: [:executor])).check

    assert_equal :absent, report[:planes][:member]
    assert_equal :live, report[:planes][:executor_transport]
  end

  # The repair that DOES happen, and where it happens: before the request, not
  # after the refusal. An expired credential is refreshed by the gem inside
  # `credential_for`, so the probe presents a live one and never sees a 401.
  def test_an_expired_credential_is_refreshed_before_it_is_presented
    rotated = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: "sk-fresh", executor_access_token: TRANSPORT,
      refresh_token: "rt-next", token_type: "Bearer", expires_in: 1_209_600
    )
    credentials = oauth(authority: rotating_authority(rotated: rotated), expires_in: 0)
    @api.accept(MEMBER, false)
    @api.accept("sk-fresh", true)

    report = authority_for(credentials).check
    assert_equal :live, report[:planes][:member]
    assert_includes @api.calls, ["/agent_api/v1/profile", "sk-fresh"]
  end

  # The one thing a refusal may still cost: nothing. If the renewal thread
  # rotates between our pre-read of the counter and the refusal, the credential
  # we presented is one moment stale and the live one is already on disk —
  # adopting it is free.
  def test_a_rotation_landing_mid_probe_is_adopted_without_spending
    spent = 0
    credentials = nil
    rotating = Object.new
    rotating.define_singleton_method(:rotate) do |refresh_token:|
      spent += 1
      CybrosAgent::DeviceFlow::Credentials.new(
        access_token: "sk-renewed", executor_access_token: TRANSPORT,
        refresh_token: "rt-next", token_type: "Bearer", expires_in: 1_209_600
      )
    end
    credentials = oauth(authority: rotating)
    @api.accept(MEMBER, false)
    @api.accept("sk-renewed", true)
    # The renewal thread, landing while the member probe is in flight.
    @api.define_singleton_method(:call) do |path, credential:, timeout:, **rest|
      credentials.agent.refresh if credential == MEMBER && spent.zero?
      super(path, credential: credential, timeout: timeout, **rest)
    end

    report = authority_for(credentials).check

    assert_equal :live, report[:planes][:member]
    assert_equal 1, spent, "renewal's rotation is the only one; the probe added none"
    assert_includes @api.calls, ["/agent_api/v1/profile", "sk-renewed"]
  end

  # The rule that keeps a read from spending. `credential_for` already ran the
  # gem's proactive refresh, so a 401 arrives on a credential that is by
  # construction not stale — rotating again could only spend a single-use
  # token to be told the same thing twice. Before this, a revoked address made
  # every `/status` poll spend one, forever.
  def test_a_refused_credential_is_never_rotated_by_the_probe
    spent = 0
    counting = Object.new
    counting.define_singleton_method(:rotate) do |refresh_token:|
      spent += 1
      CybrosAgent::DeviceFlow::Credentials.new(
        access_token: MEMBER, executor_access_token: TRANSPORT,
        refresh_token: "rt-next", token_type: "Bearer", expires_in: 1_209_600
      )
    end
    credentials = oauth(authority: counting)
    @api.accept(MEMBER, false)
    @api.accept(TRANSPORT, false)

    3.times { authority_for(credentials).check }

    assert_equal 0, spent, "a poll must not be able to spend a single-use token"
    assert_equal :unauthorized, authority_for(credentials).check[:planes][:member]
  end

  def test_a_credential_refused_twice_is_refused
    credentials = oauth
    @api.accept(MEMBER, false)

    report = authority_for(credentials).check
    assert_equal :unauthorized, report[:planes][:member]
  end

  # Nexus being unreachable says nothing about our authority. Reporting the
  # plane dead here would send a human to redo a ceremony they do not need.
  def test_an_unreachable_nexus_is_not_reported_as_lost_authority
    broken = Object.new
    def broken.call(_path, credential:, timeout:, **)
      CybrosAgent::Response.new(status: 503, headers: {}, body: nil)
    end

    report = Rho::Authority.new(oauth: oauth, base_url: @home.base_url, transport: broken, mode: "agent").check
    assert_equal :unknown, report[:planes][:member]
    refute report[:lost]
  end

  # Terminal loss is not a plane fact: revoking any credential of the lineage
  # ends every plane at once, and the remedy is a new ceremony.
  def test_a_terminally_lost_lineage_is_reported_as_such
    lost = CybrosAgent::DeviceFlow::AuthorizationLostError.new(oauth_error: "invalid_grant")
    credentials = oauth(authority: rotating_authority(failure: lost), expires_in: 0)
    @api.accept(MEMBER, false)
    @api.accept(TRANSPORT, false)

    report = authority_for(credentials).check
    assert report[:lost]
    assert_equal :unauthorized, report[:planes][:member]
  end
end
