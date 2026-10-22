require "test_helper"

# The connection ceremony, driven through the real SDK against a scripted wire.
# The point of testing it this way rather than against a stubbed SDK is that
# every rule Round D built into the wire — the plane a bundle leads with, the
# absence of any identity in the token response, the two bootstrap reads — has
# to actually hold for this code to work.
class ConnectionTest < Minitest::Test
  include NexusDoubles

  FakeOAuth = NexusDoubles::FakeOAuth
  FakeAgentApi = NexusDoubles::FakeAgentApi

  def setup
    @root = Dir.mktmpdir("rho-connection")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    @oauth = FakeOAuth.new
    @api = FakeAgentApi.new
    @locks = []
  end

  def teardown
    @locks.each(&:release)
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def device_flow(oauth = @oauth)
    CybrosAgent::DeviceFlow::Client.new(
      base_url: @home.base_url, transport: oauth, sleeper: ->(_seconds) { nil }
    )
  end

  # Agent mode by default: the agent shape is branch A exactly as it was,
  # and the full/runner shapes are pinned by name below.
  def connection(oauth: @oauth, api: @api, mode: "agent", **options)
    Rho::Connection.new(
      home: @home, device_flow: device_flow(oauth), api_transport: api,
      display_name: "Helper", mode: mode, **options
    )
  end

  def connect(**options)
    connection(**options).tap { |c| c.start ; c.await }
  end

  def pointer = Rho::StateFile.new(@home.connection_pointer_path).read

  def test_the_agent_files_itself_under_the_profiles_member_identity
    connection = connect

    assert_equal :active, connection.phase
    assert_equal "0199-user", connection.identity.user_public_id
    assert_equal @home.identity_root("0199-user"), connection.identity.root
  end

  # The token response names no destination, so the address
  # comes from `/executor` — the plane whose whole answer is "which address is
  # this credential". `/profile` cannot supply it: the member plane never
  # reports the caller's own address.
  def test_the_agent_learns_its_own_address_from_executor
    connection = connect

    assert_equal "0199-executor", connection.identity.executor_public_id
    assert_includes @api.requests.map { |path, credential, _params| [path, credential] },
      ["/agent_api/v1/executor", TRANSPORT_TOKEN]
  end

  def test_the_agent_reads_each_plane_with_its_own_credential
    connection = connect

    assert_equal(
      [["/agent_api/v1/executor", TRANSPORT_TOKEN], ["/agent_api/v1/profile", MEMBER_TOKEN]],
      @api.requests.map { |path, credential, _params| [path, credential] }.sort
    )
    assert_equal(
      {
        planes: { member: :live, executor_transport: :live },
        lost: false,
        member_handle: "helper",
      },
      connection.authority_report,
      "the two bootstrap reads are also the fresh authority observation"
    )
  end

  # ---- the three request shapes of ONE Connection ----

  # THE IDENTIFIER PRESENTED is the program's constant plus this home's instance part —
  # `rho.<id>`, `rho-runner.<id>` — so several installs of one program pair under one
  # steward as separate rows; the constants stay the program's name.
  def test_the_three_shapes_name_their_identifiers
    assert_equal "rho", Rho::AGENT_IDENTIFIER, "the wire identity is a release-stable product constant"
    instance = @home.instance_id
    assert_match(/\A[0-9a-f]{8}\z/, instance)

    connect(mode: "agent")
    agent_params = @oauth.requests.first.last
    assert_equal "rho.#{instance}", agent_params[:agent_identifier]
    assert_equal %i[agent_display_name agent_identifier client_id executor_display_name], agent_params.keys.sort

    full = FakeOAuth.new
    connect(mode: "full", oauth: full)
    assert_equal agent_params, full.requests.first.last, "full mode connects the same application"
    assert_equal 1, full.requests.count { |path, _| path == "/oauth/device_authorization" }

    standalone = FakeOAuth.new
    connect(mode: "runner", oauth: standalone)
    runner_params = standalone.requests.first.last
    assert_equal %i[client_id executor_kind registration_identifier runner_display_name], runner_params.keys.sort
    assert_equal ["rho-runner.#{instance}", "runner"], runner_params.values_at(:registration_identifier, :executor_kind)
  end

  # Two homes present two identifiers; one home twice presents one (a
  # reconnect re-pairs the same Profile and fences the previous device).
  def test_two_homes_present_two_identifiers_and_one_home_twice_presents_one
    other_root = Dir.mktmpdir("rho-connection-other")
    other = Rho::Home.resolve(base_url: "https://nexus.example", root: other_root).prepare
    first = FakeOAuth.new
    again = FakeOAuth.new
    elsewhere = FakeOAuth.new

    connect(mode: "agent", oauth: first)
    connect(mode: "agent", oauth: again)
    Rho::Connection.new(home: other, device_flow: device_flow(elsewhere), api_transport: FakeAgentApi.new,
      display_name: "Helper", mode: "agent").tap { |c| c.start ; c.await }

    presented = [first, again, elsewhere].map { |oauth| oauth.requests.first.last.fetch(:agent_identifier) }
    assert_equal presented[0], presented[1], "one home, one identifier"
    refute_equal presented[0], presented[2], "two homes, two identifiers"
    assert_equal "rho.#{other.instance_id}", presented[2]
  ensure
    FileUtils.remove_entry(other_root) if other_root && File.directory?(other_root)
  end

  def test_full_mode_pairs_once_and_files_one_application_lineage
    connection = connect(mode: "full")
    assert_equal :active, connection.phase
    identity = connection.identity
    assert_equal "full", identity.mode
    assert_equal "0199-user", identity.user_public_id
    assert_equal "0199-executor", identity.executor_public_id
    assert_equal identity.executor_public_id, identity.runner_executor_public_id
    assert_equal [["/agent_api/v1/executor", TRANSPORT_TOKEN], ["/agent_api/v1/profile", MEMBER_TOKEN]],
      @api.requests.map { |path, credential, _params| [path, credential] }.sort
    assert_equal({ planes: { member: :live, executor_transport: :live }, lost: false,
      member_handle: "helper" }, connection.authority_report)
    assert_equal [MEMBER_TOKEN, TRANSPORT_TOKEN], [connection.oauth.member_credential, connection.oauth.executor_credential]
    assert_equal 1, connection.oauth.lineages.length
    assert_nil identity.runner_vault.read
    assert_equal MEMBER_TOKEN, identity.vault.read.fetch("access_token")
    refute pointer.key?("runner_executor_public_id")
    assert_equal({ "branch" => "agent", "mode" => "full" }, connection.to_h.slice("branch", "mode"))
  end

  def test_runner_mode_pairs_the_one_lineage_under_the_runner_root
    connection = connect(mode: "runner")

    identity = connection.identity
    assert_equal "runner", identity.mode
    assert_nil identity.user_public_id
    assert_equal "0199-runner", identity.executor_public_id
    assert_equal @home.runner_identity_root("0199-runner"), identity.root
    assert_equal [["/agent_api/v1/executor", RUNNER_TOKEN]],
      @api.requests.map { |path, credential, _params| [path, credential] }, "no /profile read: a runner has no user"
    assert_equal({ planes: { runner_transport: :live }, lost: false }, connection.authority_report)
    about = connection.oauth
    refute about.agent?
    assert_equal RUNNER_TOKEN, about.runner_credential
    assert_equal RUNNER_TOKEN, identity.runner_vault.read.fetch("executor_access_token")
    refute File.exist?(identity.vault.path), "no agent lineage was filed"
    assert_equal({ "version" => 5, "mode" => "runner", "executor_public_id" => "0199-runner",
                   "runner_registration_identifier" => "rho.imported-runner" }, pointer)
    assert_equal "runner", connection.to_h.fetch("branch")
  end

  # A grant that names a runner and answers a non-runner kind is refused
  # — and the agent half installs nothing, so a retry resumes at activation.
  def test_a_runner_grant_naming_a_non_runner_kind_is_refused_and_installs_nothing
    api = FakeAgentApi.new
    api.define_singleton_method(:runner_executor) do
      { "executor" => { "public_id" => "0199-runner", "kind" => "tool_provider", "status" => "active", "service_roles" => ["tool_provider"],
                        "display_name" => "Helper", "presence" => "offline", "credential_epoch" => 1 },
        "measured_at" => "2026-07-26T00:00:00Z" }
    end
    connection = connection(mode: "runner", api: api)
    connection.start

    error = assert_raises(Rho::ConnectionError) { connection.await }
    assert_match(/the runner grant named a tool_provider/, error.message)
    assert_nil pointer
    refute File.exist?(@home.identity_root("0199-user")), "nothing was filed"
    refute_nil Rho::StateFile.new(@home.pending_connection_path).read, "the bundle stays staged for a retry"
  end

  def test_full_mode_restore_replaces_the_application_owner_and_keeps_one_address
    first = connect(mode: "full")
    restored = connect(mode: "full", oauth: FakeOAuth.new, request: :agent,
      existing: first.oauth, existing_identity: first.identity)
    refute_same first.oauth.agent, restored.oauth.agent
    assert_equal 1, restored.oauth.lineages.length
    assert_equal first.identity.executor_public_id, restored.identity.runner_executor_public_id
    assert_nil restored.oauth.runner
    refute pointer.key?("runner_executor_public_id")
  end

  def test_full_mode_cannot_start_a_separate_runner_registration
    assert_raises(ArgumentError) { connection(mode: "full", request: :runner) }
  end

  def test_agent_identity_documents_carry_the_mode_and_only_agent_identity_facts
    connection = connect

    assert_equal(
      %w[agent_identifier executor_public_id mode user_public_id version],
      connection.identity.pointer_document.keys.sort
    )
    assert_equal(
      %w[agent_identifier base_url connected_at executor_public_id mode user_public_id version],
      connection.identity.session.read.keys.sort
    )
    assert_equal(
      %w[executor_public_id instance_id user_public_id],
      connection.to_h.fetch("identity").keys.sort
    )
    assert_equal @home.instance_id, connection.to_h.dig("identity", "instance_id"),
      "the ceremony document says which instance paired (the pointer does not: it is the identity's public ids)"
    assert_equal(%w[branch identity mode phase], connection.to_h.keys.sort)
  end

  def test_the_credentials_land_in_the_destination_vault
    connection = connect

    vault = connection.identity.vault.read
    assert_equal MEMBER_TOKEN, vault["access_token"]
    assert_equal TRANSPORT_TOKEN, vault["executor_access_token"]
    assert_equal 0o600, File.stat(connection.identity.vault.path).mode & 0o777
  end

  # Staging is a hand-off buffer for the one window between the mint and the
  # install, and never an active credential source.
  def test_staging_is_gone_once_the_credentials_are_installed
    connect

    assert_empty Dir.glob(File.join(@home.connections_root, "*"))
  end

  def test_the_installation_points_at_the_identity_it_connected_as
    connect

    assert_equal Rho::Identity::SESSION_VERSION, pointer["version"]
    assert_equal "0199-user", pointer["user_public_id"]
  end

  def test_the_identity_root_records_which_nexus_it_belongs_to
    connection = connect

    session = connection.identity.session.read
    assert_equal @home.base_url, session["base_url"]
    assert_equal "0199-executor", session["executor_public_id"]
  end

  # A directory copied from another installation must not be adopted: the
  # installation key is a digest, so a moved tree looks native.
  def test_an_identity_root_from_another_nexus_is_refused
    connection = connect
    session = connection.identity.session
    session.write(session.read.merge("base_url" => "https://elsewhere.example"))

    assert_raises(Rho::StoredConnectionError) { connect }
  end

  # Revoking an address is terminal, but it does not revoke the Agent
  # or bind that Profile to the dead address forever. The next winning Consume
  # creates a new address for the same Profile, and the current installation
  # moves to it without moving or renaming the user-scoped identity root.
  def test_a_new_connection_can_roll_the_same_agent_user_to_a_new_executor
    first = connect
    old_root = first.identity.root

    replacement = connect(api: FakeAgentApi.new(executor_public_id: "0199-executor-new"))

    assert_equal old_root, replacement.identity.root
    assert_equal "0199-user", replacement.identity.user_public_id
    assert_equal "0199-executor-new", replacement.identity.executor_public_id
    assert_equal "0199-executor-new", pointer["executor_public_id"]
    assert_equal "0199-executor-new", replacement.identity.session.read["executor_public_id"]
  end

  def test_the_phases_a_human_watches_are_reported_in_order
    phases = []
    connection = connection(on_phase: ->(phase) { phases << phase })
    connection.start

    assert_equal %i[starting pending], phases
    assert_equal "BCDF-GHJK", connection.user_code
    assert_equal "https://nexus.example/oauth/device", connection.verification_uri

    connection.await
    assert_equal %i[starting pending activating active], phases
  end

  def test_a_pending_connection_publishes_what_the_human_needs_and_nothing_else
    connection = connection()
    connection.start

    document = connection.to_h
    assert_equal "pending", document["phase"]
    assert_equal "BCDF-GHJK", document["user_code"]
    refute_includes document.to_s, "dc-cybros", "the device code is a secret, unlike the user code"
  end

  # The whole reason staging exists. Activation failed after the ceremony was
  # already won, so a retry resumes at activation — running the browser
  # ceremony again would re-pair the same address at a later epoch and fence
  # the staged bundle this retry still needs to install.
  def test_a_failed_activation_leaves_the_ceremony_won_and_resumable
    refusing = Object.new
    def refusing.call(_path, credential:, timeout:, **)
      CybrosAgent::Response.new(status: 500, headers: {}, body: nil)
    end

    connection = connection(api: refusing)
    connection.start
    assert_raises(CybrosAgent::Api::ServerError) { connection.await }
    assert_equal :error, connection.phase
    assert_equal 2, @oauth.requests.length, "the ceremony itself must not be re-run"

    resumed = connection(api: @api)
    assert resumed.resume
    assert_equal :active, resumed.phase
    assert_equal "0199-user", resumed.identity.user_public_id
  end

  def test_legacy_agent_pointer_without_an_executor_fails_closed
    error = assert_raises(Rho::StoredConnectionError) do
      Rho::Identity.from_pointer(
        home: @home,
        pointer: {
          "version" => Rho::Identity::SESSION_VERSION,
          "mode" => "agent",
          "user_public_id" => "0199-user",
        }
      )
    end

    assert_match(/missing an Agent identity public id/, error.message)
  end

  def test_an_old_connection_pointer_format_fails_closed
    error = assert_raises(Rho::StoredConnectionError) do
      Rho::Identity.from_pointer(
        home: @home,
        pointer: {
          "version" => Rho::Identity::SESSION_VERSION - 1,
          "mode" => "agent",
          "user_public_id" => "0199-user",
          "executor_public_id" => "0199-executor",
        }
      )
    end

    assert_match(/format version/, error.message)
  end

  def test_an_old_staging_format_fails_closed
    staging = Rho::StateFile.new(@home.pending_connection_path)
    staging.write(
      "version" => Rho::Connection::STAGING_VERSION - 1,
      "base_url" => @home.base_url
    )

    error = assert_raises(Rho::StoredConnectionError) { connection.resume }

    assert_match(/format version/, error.message)
  end

  def test_resume_reports_that_there_is_nothing_to_resume
    refute connection.resume
  end

  # An Agent authorization must produce the two-plane shape it requested.
  # The SDK rejects a transport-only response at the token boundary, before
  # rho could attempt a bootstrap read with an incomplete bundle.
  def test_an_agent_without_a_member_credential_is_terminally_refused
    oauth = FakeOAuth.new(plane: "executor_transport", with_executor: false)
    connection = connection(oauth: oauth)
    connection.start

    error = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { connection.await }
    assert_match(/authorization branch/, error.message)
  end

  # A failure after the ceremony is won must leave a RETRYABLE state — the
  # staged bundle survives so a retry resumes at activation rather than asking
  # the human for a second browser round. This used to be false: activation
  # took a second, identity-scoped lock that no failure path released, so one
  # injected failure wedged every later attempt on AlreadyHeld, naming a lock
  # this very process held. The lock is gone (the home's boot lock already
  # excludes every process the identity lock could have), and the claim in
  # this class's header is true again.
  def test_a_failed_filing_leaves_the_next_attempt_able_to_resume
    failed = false
    first = connection()
    first.define_singleton_method(:install) do
      failed = true
      raise Rho::StateError, "injected failure"
    end
    first.start
    assert_raises(Rho::StateError) { first.await }
    assert failed

    second = connection()
    second.start
    second.await

    assert_equal :active, second.phase
  end

  # The wedge the deferral ledger recorded: install writes the pointer and
  # then deletes the staging slot, and a crash between the two leaves the
  # bundle behind. Once the steward later revokes the lineage, every new
  # connection resumes that stale bundle, is refused, and — because a failed
  # FILING deliberately stays staged — keeps it for the next attempt too.
  # Clicking connect can never escape. The repair is at the refusal: a 401 on
  # the bootstrap read is the one failure that spends the bundle, because its
  # whole job was to be accepted there and a 401 is never transient.
  def test_a_refused_bundle_is_spent_rather_than_kept_for_every_later_resume
    first = connection()
    # The crash window, exactly: vault and pointer written, staging delete
    # never reached.
    first.instance_variable_get(:@staging).define_singleton_method(:delete) { nil }
    first.start
    first.await
    assert_equal :active, first.phase

    # The steward revokes the connection; every bootstrap read now refuses.
    refusing = Object.new
    refusing.define_singleton_method(:call) do |_path, credential:, timeout:, **|
      CybrosAgent::Response.new(
        status: 401, headers: {},
        body: { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } }
      )
    end

    second = connection(api: refusing)
    assert_raises(CybrosAgent::Api::Unauthorized) { second.resume }

    # The refusal spent the bundle: the next attempt must find nothing to
    # resume and run a real ceremony — against a Nexus that accepts it again,
    # it completes.
    recovered = connection()
    refute recovered.resume, "a bundle already refused must not be offered to the next attempt"
    recovered.start
    recovered.await
    assert_equal :active, recovered.phase
  end

  # Kills abandon waits, never commits. Orderly code may kill the ceremony's
  # wait only after Nexus cancellation proves Consume did not win; once the
  # kernel has minted the bundle, a kill landing between the poll returning
  # and staging orphans a refresh-token lineage nobody will ever present.
  # Staging is
  # interrupt-atomic, so the kill lands after the bundle is durable and the
  # next attempt resumes instead of re-asking.
  def test_a_kill_cannot_separate_a_won_ceremony_from_its_staged_bundle
    staging = Queue.new
    gate = Queue.new
    first = connection()
    original = first.method(:stage)
    first.define_singleton_method(:stage) do |credentials|
      staging << true
      gate.pop
      original.call(credentials)
    end
    first.start
    awaiting = Thread.new { first.await }
    staging.pop # the bundle is minted and mid-commit
    awaiting.kill
    gate << true
    refute_nil awaiting.join(5)

    second = connection()
    assert second.resume, "the won bundle must be on disk for the next attempt"
    assert_equal :active, second.phase
  end

  def test_no_diagnostic_renders_a_credential
    connection = connect(mode: "full")

    [connection.inspect, connection.to_s, connection.to_h.to_s, connection.oauth.inspect].each do |diagnostic|
      refute_includes diagnostic, "member.secret"
      refute_includes diagnostic, "transport.secret"
      refute_includes diagnostic, "runner.secret"
    end
  end

  # A crash between the mint and the install leaves the whole bundle —
  # the runner half and the branch — staged, so the next attempt files both.
  def test_a_staged_full_mode_bundle_resumes_the_application_owner
    first = connection(mode: "full")
    first.define_singleton_method(:install) { raise Rho::StateError, "injected failure" }
    first.start
    assert_raises(Rho::StateError) { first.await }
    staged = Rho::StateFile.new(@home.pending_connection_path).read
    assert_equal 6, staged.fetch("version")
    assert_equal "agent", staged.fetch("branch")
    refute staged.key?("runner")

    second = connection(mode: "full")
    assert second.resume
    assert_equal :active, second.phase
    assert_equal TRANSPORT_TOKEN, second.oauth.executor_credential
    assert_equal second.identity.executor_public_id, second.identity.runner_executor_public_id
  end
end
