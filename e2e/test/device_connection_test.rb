require "test_helper"
require "support/runner_grant"
require "support/secret_hygiene"

# The Round C connection journey against a booted Nexus through public HTML and HTTP surfaces only:
# found the installation, start a device authorization with the typed SDK, connect it in the
# browser, poll for the credential pair, verify the Agent User mapping in the admin console, then
# prove family A's replay cascade before reconnecting and independently revoking family B.
class DeviceConnectionTest < Minitest::Test
  AGENT_IDENTIFIER = "cybros-e2e-agent".freeze
  REGISTRATION_IDENTIFIER = "cybros-e2e-runner".freeze

  def setup
    @base_url = E2E.base_url
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @client = CybrosAgent::DeviceFlow::Client.new(
      base_url: @base_url,
      # The injected sleeper compresses every computed wait to 0.2s of real
      # time so the journey stays quick; interval pacing itself is proven in
      # the SDK's unit suite against a fake clock.
      sleeper: ->(_seconds) { sleep 0.2 }
    )
    found_installation
  end

  def teardown
    unless passed?
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/device_connection-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not save E2E browser screenshot: #{error.class}: #{error.message}"
  ensure
    @actor&.close
  end

  def test_device_connection_cancel_rotate_revoke_and_reuse_rejection
    # Before the human acts, the typed machine leg observes RFC pending. A
    # browser cancellation then maps to RFC access_denied without creating an
    # Agent User.
    canceled = request_authorization
    assert_instance_of CybrosAgent::DeviceFlow::Pending, @client.poll(canceled)
    cancel_in_browser(canceled)

    canceled_error = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      @client.poll(canceled)
    end
    assert_equal "access_denied", canceled_error.oauth_error
    verify_cancellation_has_no_materialized_identity

    # Family A begins with the agent program's first connection.
    authorization = request_authorization

    # The human connects it in the browser without choosing an Agent, scopes,
    # display name, or executor.
    connect_in_browser(authorization)

    # The program polls and receives its credential bundle: one connection, both planes.
    credentials = @client.await_credentials(authorization)
    assert credentials.access_token.start_with?("sk-cybros-api-v1-")
    assert credentials.executor_access_token.start_with?("sk-cybros-api-v1-")
    assert credentials.refresh_token.start_with?("rt-cybros-api-v1-")
    assert_predicate credentials, :member_plane?
    assert_predicate credentials, :executor_plane?

    profile_public_id = verify_both_planes_answer_their_own_resources(credentials)

    # The public admin console reflects the Agent User mapping while keeping
    # user-bound executor and credential details out of the admin plane. The
    # typed lifecycle below proves those internal connection consequences.
    verify_connection_in_admin_console

    # The program rotates family A, then replays the predecessor. Reuse is
    # rejected and immediately fences the live successor too.
    successor = @client.rotate(refresh_token: credentials.refresh_token)
    assert successor.access_token.start_with?("sk-cybros-api-v1-")
    refute credentials.refresh_token == successor.refresh_token

    reuse = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      @client.rotate(refresh_token: credentials.refresh_token)
    end
    assert_equal "invalid_grant", reuse.oauth_error

    fenced_successor = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      @client.rotate(refresh_token: successor.refresh_token)
    end
    assert_equal "invalid_grant", fenced_successor.oauth_error

    # A second public connection reconnects the same program and establishes
    # family B. Explicit access-token revocation then fences its current
    # refresh token without exposing whether the bearer existed.
    reconnect = request_authorization
    connect_in_browser(reconnect)
    reconnected = @client.await_credentials(reconnect)
    assert reconnected.access_token.start_with?("sk-cybros-api-v1-")
    assert reconnected.refresh_token.start_with?("rt-cybros-api-v1-")
    reconnected_profile = CybrosAgent::Client
      .new(base_url: @base_url, credential: reconnected.access_token).profile.fetch
    assert_equal profile_public_id, reconnected_profile.member.public_id,
      "the same Agent product constant reconnects the same Profile registration"

    assert_nil @client.revoke(token: reconnected.access_token)

    revoked_current = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      @client.rotate(refresh_token: reconnected.refresh_token)
    end
    assert_equal "invalid_grant", revoked_current.oauth_error
  end

  # The runner branch end to end: identity-less, transport-only, and re-pairing in place. It runs as
  # its own journey because a machine never resolves an Agent — the whole point of the
  # branch.
  def test_runner_connection_re_pairs_in_place_and_fences_the_previous_credential
    E2E::DeviceAuthorizationBudget.consume
    authorization = @client.request_runner_authorization(
      registration_identifier: REGISTRATION_IDENTIFIER, runner_display_name: "E2E workshop"
    )
    assert_equal :runner, authorization.branch

    connect_in_browser(authorization)

    credentials = @client.await_credentials(authorization)
    assert_nil credentials.access_token, "a runner is a delivery address, never a member principal"
    assert credentials.executor_access_token.start_with?("sk-cybros-api-v1-")
    refute_predicate credentials, :member_plane?

    # Only the executor plane exists for it, and that plane is enough to
    # bootstrap: the machine learns which address it is without ever calling
    # a member endpoint.
    planes = CybrosAgent.planes_for(credentials, base_url: @base_url)
    assert_nil planes.client
    description = planes.executor_client.executor
    assert_equal "runner", description.executor.kind
    assert_equal "E2E workshop", description.executor.display_name
    address_public_id = description.executor.public_id
    assert_equal 1, description.executor.credential_epoch

    # Its transport credential is refused on the member plane, exactly as a
    # member credential is refused on the executor plane.
    assert_raises(CybrosAgent::Api::Unauthorized) do
      CybrosAgent::Client.new(base_url: @base_url, credential: credentials.executor_access_token).profile.fetch
    end

    # Reconnecting the same (account_id, manager_id, registration_identifier) key
    # re-pairs the same public address, advances its epoch, and fences the
    # previous credential. The existing private scope is not selected again.
    E2E::DeviceAuthorizationBudget.consume
    reconnect = @client.request_runner_authorization(
      registration_identifier: REGISTRATION_IDENTIFIER, runner_display_name: "E2E workshop"
    )
    connect_in_browser(reconnect, existing_runner_scope: :user_private)
    reconnected = @client.await_credentials(reconnect)

    repaired = CybrosAgent::ExecutorClient
      .new(base_url: @base_url, credential: reconnected.executor_access_token).executor
    assert_equal address_public_id, repaired.executor.public_id, "a reconnect re-pairs, never duplicates"
    assert_equal 2, repaired.executor.credential_epoch

    fenced = assert_raises(CybrosAgent::Api::Unauthorized) do
      planes.executor_client.executor
    end
    assert_equal "unauthorized", fenced.code

    # The manager governs the machine from their own console page, and
    # revoking its credentials leaves the machine itself connected.
    @actor.visit("/runners")
    assert @page.has_text?("E2E workshop")
    @page.find("tr", text: "E2E workshop").click_button("Revoke credentials")
    # The console confirms through its own themed dialog, never a native confirm.
    @page.find("#turbo-confirm[open] button[value='confirm']").click
    assert @page.has_text?("Credentials revoked. The machine keeps its identity.")
    assert @page.has_text?("No credential")

    assert_raises(CybrosAgent::Api::Unauthorized) do
      CybrosAgent::ExecutorClient
        .new(base_url: @base_url, credential: reconnected.executor_access_token).executor
    end
  end

  def test_combined_connection_preserves_an_existing_account_wide_runner
    registration_identifier = "#{REGISTRATION_IDENTIFIER}-combined"
    E2E::DeviceAuthorizationBudget.consume
    authorization = @client.request_runner_authorization(
      registration_identifier: registration_identifier, runner_display_name: "E2E shared workshop"
    )
    connect_in_browser(authorization, account_wide: true)
    credentials = @client.await_credentials(authorization)
    original_client = CybrosAgent.planes_for(credentials, base_url: @base_url).executor_client
    original = original_client.executor.executor

    # A combined grant can re-pair a runner first registered through the standalone flow.
    # Both browser pages must describe the scope that the winning consume will retain.
    E2E::DeviceAuthorizationBudget.consume
    combined = @client.request_authorization(
      agent_identifier: "#{AGENT_IDENTIFIER}-combined",
      agent_display_name: "E2E combined helper", executor_display_name: "E2E combined app",
      runner: { identifier: registration_identifier, display_name: "E2E shared workshop" }
    )
    assert_equal :combined, combined.branch
    @page.current_window.resize_to(1400, 1000)
    E2E::RunnerGrant.visit_connection(actor: @actor, authorization: combined)
    assert @page.has_text?(/Also runs as a runner.*available account-wide/)
    assert @page.has_no_text?(/private to .*Agents/)
    E2E::SecretHygiene.save_screenshot(
      @actor, File.expand_path("../artifacts/screenshots/device_connection-combined-desktop.png", __dir__)
    )

    @page.current_window.resize_to(390, 844)
    assert @page.has_text?(/Also runs as a runner.*available account-wide/)
    assert @page.has_no_text?(/private to .*Agents/)
    E2E::RunnerGrant.connect_in_browser(actor: @actor, authorization: combined)
    assert @page.has_text?(/Also runs as a runner.*available account-wide/)
    assert @page.has_no_text?(/private to .*Agents/)
    E2E::SecretHygiene.save_screenshot(
      @actor, File.expand_path("../artifacts/screenshots/device_connection-combined-narrow.png", __dir__)
    )

    reconnected = @client.await_credentials(combined)
    planes = CybrosAgent.planes_for(reconnected, base_url: @base_url)
    repaired = planes.runner_client.executor.executor
    assert_equal original.public_id, repaired.public_id
    assert_equal original.credential_epoch + 1, repaired.credential_epoch
    assert_equal "account_wide", planes.client.executors.show(repaired.public_id).assignment_scope
    assert_raises(CybrosAgent::Api::Unauthorized) { original_client.executor }
    fenced_refresh = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      @client.rotate(refresh_token: credentials.refresh_token)
    end
    assert_equal "invalid_grant", fenced_refresh.oauth_error
  end

  private

  # Each credential answers on its own plane and nowhere else.
  def verify_both_planes_answer_their_own_resources(credentials)
    planes = CybrosAgent.planes_for(credentials, base_url: @base_url)

    profile = planes.client.profile.fetch
    assert_equal "agent", profile.member.kind
    assert_equal "member", profile.member.role
    assert_equal "E2E helper", profile.member.display_name
    assert_equal "member", profile.credential.plane

    description = planes.executor_client.executor
    assert_equal "agent_application", description.executor.kind
    assert_equal 1, description.executor.credential_epoch,
      "a first connection pairs the address at epoch one"

    # Cross-plane presentation is fenced, never accepted with a degraded
    # principal: the member credential cannot read the executor resource, and
    # the transport credential cannot read the member one.
    assert_raises(CybrosAgent::Api::Unauthorized) do
      CybrosAgent::ExecutorClient.new(base_url: @base_url, credential: credentials.access_token).executor
    end
    assert_raises(CybrosAgent::Api::Unauthorized) do
      CybrosAgent::Client.new(base_url: @base_url, credential: credentials.executor_access_token).profile.fetch
    end

    profile.member.public_id
  end

  # Found the installation through the public first-boot form. First-boot
  # signup exists once per database, so a later journey in the same booted
  # server signs the founding owner in instead of founding again — the
  # public path a returning human takes.
  def found_installation
    @actor.visit("/setup")
    return sign_in_founding_owner unless @page.has_field?("Installation name", wait: 2)

    @page.fill_in "Installation name", with: "E2E"
    @page.fill_in "Your name", with: "E2E Owner"
    @page.fill_in "Email", with: "owner@e2e.test"
    @page.fill_in "Password", with: "e2e password strong"
    @page.fill_in "Repeat password", with: "e2e password strong"
    @page.click_button "Create installation"

    assert @page.has_selector?("h1", text: "Dashboard")
  end

  def sign_in_founding_owner
    @actor.visit("/session/new")
    @page.fill_in "Email", with: "owner@e2e.test"
    @page.fill_in "Password", with: "e2e password strong"
    # POST /session is IP rate-limited; the suite-wide budget keeps every
    # journey's login inside it.
    E2E::SessionSignInBudget.consume
    @page.click_button "Sign in"

    assert @page.has_text?("Dashboard")
  end

  def request_authorization
    E2E::DeviceAuthorizationBudget.consume
    authorization = @client.request_authorization(
      agent_identifier: AGENT_IDENTIFIER,
      agent_display_name: "E2E helper",
      executor_display_name: "E2E app"
    )
    assert_match(/\A[A-Z]{4}-[A-Z]{4}\z/, authorization.user_code)
    assert_equal "#{@base_url}/oauth/device", authorization.verification_uri
    assert_equal(
      "#{@base_url}/oauth/device?user_code=#{authorization.user_code}",
      authorization.verification_uri_complete
    )
    authorization
  end

  # This journey's own `visit_connection` carries the page's negative pins
  # (no identifier, no scope, no selector leaks); the grant itself is the
  # harness's shared helper (`E2E::RunnerGrant`), so a second executor gets
  # its credential through exactly the ceremony this journey proves.
  def connect_in_browser(authorization, account_wide: false, existing_runner_scope: nil)
    visit_connection(authorization)
    E2E::RunnerGrant.connect_in_browser(
      actor: @actor, authorization: authorization,
      account_wide: account_wide, existing_runner_scope: existing_runner_scope
    )
  end

  def cancel_in_browser(authorization)
    visit_connection(authorization)

    assert @page.has_button?("Connect")
    assert @page.has_button?("Cancel")
    @page.click_button "Cancel"
    assert @page.has_text?("This connection was canceled. No credential was shared with the agent program.")
  end

  def visit_connection(authorization)
    runner = authorization.branch == :runner
    @actor.visit(authorization.verification_uri_complete)
    assert @page.has_field?("Device code", with: authorization.user_code)

    @page.click_button "Continue"
    assert @page.has_text?(runner ? "Connect runner" : "Connect agent program")
    assert @page.has_text?(authorization.user_code)
    subject_heading = runner ? "Runner" : "Agent program"
    assert_equal [subject_heading], @page.all("section h2").map(&:text)
    connection_facts = @page.find("h2", text: subject_heading, exact_text: true).ancestor("section")
    assert_equal ["Type", "Expires"],
      connection_facts.all("div.border-b > div:first-child > p").map(&:text)
    identifier = runner ? REGISTRATION_IDENTIFIER : AGENT_IDENTIFIER
    assert @page.has_no_text?(identifier)
    assert @page.has_no_text?("E2E helper")
    assert @page.has_no_text?("E2E workshop")
    assert @page.has_no_text?("Requested scopes")
    assert @page.has_no_text?("E2E app")
    assert @page.has_no_text?("Creates your Agent")
    assert @page.has_no_text?("Reconnects the agent program")
    assert @page.has_no_text?("Restores your removed Agent")
    assert @page.has_no_selector?("input[type='radio']")
    assert @page.has_no_selector?("select")
  end

  def verify_cancellation_has_no_materialized_identity
    @actor.visit("/admin/users")
    assert @page.has_text?("Members")
    assert @page.has_no_text?("E2E helper")
  end

  def verify_connection_in_admin_console
    @actor.visit("/admin/users")
    @page.click_link "E2E helper"
    assert @page.has_text?("Member administration")
    assert_equal "active", fact_value("Status")
    assert_equal "E2E Owner", fact_value("Steward")
    # A "Receiving work" fact was asserted absent here for a long time and
    # named nothing this application has ever rendered — not at HEAD, not
    # before the console was unified, and not in the predecessor. A check that
    # cannot fail is not a check, so it is gone rather than restyled.
    assert @page.has_no_selector?("h2", text: "Credentials", exact_text: true)
    assert @page.has_no_link?("Register an executor")
    assert @page.has_no_link?("Agents & executors")
  end

  # THE SHARED FACTS PANEL IS A DEFINITION LIST. It renders `dt`/`dd` inside
  # one bordered row per fact (shared/_facts_panel.html.erb); this helper read
  # `p` elements, which is what the console looked like before it was unified,
  # and the change took the journey with it.
  def fact_value(label)
    @page.find("dt", text: label, exact_text: true).ancestor("div.border-b").find("dd").text
  end
end
