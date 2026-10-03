require "test_helper"

# Browser-held device connections: Connect/Cancel act only on a grant this browser context verified.
# The signed-in human never selects an Agent or an existing executor; for a Runner only, an
# administrator may opt into account-wide assignment while Nexus resolves the concrete registration.
class OAuth::DeviceConnectionTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      agent_identifier: "install-connect",
      agent_display_name: "Hidden helper name",
      requested_executor_display_name: "Hidden executor name",
    ).authorization
  end

  test "the connection page shows the code without exposing the product identifier" do
    verify
    get oauth_device_grant_path(@grant.public_id)

    assert_select "h1", text: "Connect agent program"
    assert_select "p", text: @grant.formatted_user_code
    assert_select "body", text: /#{Regexp.escape(@grant.agent_identifier)}/, count: 0
    assert_select "body", text: /Hidden helper name/, count: 0
    assert_select "body", text: /Hidden executor name/, count: 0
    assert_select "*", text: /\Aapi\z/, count: 0
    assert_select "[role=alert]", text: /replaces the old device immediately/
    assert_select "[role=alert]", text: /work already running there cannot move/i
    assert_select "[role=alert]", text: /only if you started it yourself/i
    assert_select "[role=alert]", text: /close this page/i

    assert_select "form[action=?]", oauth_device_grant_connection_path(@grant.public_id) do
      assert_only_return_to
      assert_select "input[type=submit][value=?]", "Connect"
    end
    assert_select "form[action=?]", oauth_device_grant_cancellation_path(@grant.public_id) do
      assert_only_return_to
      assert_select "input[type=submit][value=?]", "Cancel"
    end
    assert_select "main#main" do
      assert_select "select, input[type=radio], input[type=checkbox]", count: 0
    end
  end

  test "connecting a verified grant freezes the consequence; the profile waits for consume" do
    verify

    # Stray parameters (old branch/adopt/scope vocabulary) are ignored: the
    # consequence is derived entirely server-side.
    assert_no_difference -> { User.count } do
      post oauth_device_grant_connection_path(@grant.public_id), params: {
        return_to: oauth_device_grant_path(@grant.public_id),
        connection: {
          branch: "adopt",
          adopted_member_public_id: users(:agent).public_id,
        },
      }
    end

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.connected", subject: "agent program"), flash[:notice]

    @grant.reload
    assert @grant.connected?
    assert_equal users(:owner), @grant.connected_by
    assert_nil @grant.user

    assert_difference -> { User.where(kind: :agent).count }, 1 do
      assert_equal :minted, DeviceAuthorizations::Consume.call(authorization: @grant).outcome
    end
    assert_equal users(:owner), @grant.reload.user.steward
    assert_equal "install-connect", @grant.user.agent_identifier
  end

  test "reconnecting uses the exact Agent profile without exposing descriptive names" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      agent_identifier: users(:agent).agent_identifier,
      agent_display_name: "Program supplied rename",
      requested_executor_display_name: "Ignored executor rename",
    ).authorization

    verify
    get oauth_device_grant_path(@grant.public_id)

    assert_select "input[type=submit][value=?]", "Connect"
    assert_select "body", text: /Fixture Agent/, count: 0
    assert_select "body", text: /Program supplied rename/, count: 0
    assert_select "body", text: /Agent app/, count: 0

    post oauth_device_grant_connection_path(@grant.public_id)

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    # Both program-supplied names land only at consume, never at connection.
    # The re-pair then writes the executor's, the way a Runner's re-pair does:
    # the address is the Profile's existing sole non-revoked address, and its
    # name is whatever the program calling itself in now says it is.
    assert_equal "Fixture Agent", users(:agent).reload.display_name
    assert_equal "Agent app", task_executors(:address).reload.display_name
    assert_equal :minted, DeviceAuthorizations::Consume.call(authorization: @grant.reload).outcome
    assert_equal "Program supplied rename", users(:agent).reload.display_name
    assert_equal "Ignored executor rename", task_executors(:address).reload.display_name
  end

  test "an expired session returns an interrupted connection to its owning page" do
    verify
    get oauth_device_grant_path(@grant.public_id)
    users(:owner).increment!(:authority_generation)

    post oauth_device_grant_connection_path(@grant.public_id), params: {
      return_to: oauth_device_grant_path(@grant.public_id),
    }

    query = Rack::Utils.parse_nested_query(URI(response.location).query)
    assert_equal oauth_device_grant_path(@grant.public_id), query.fetch("return_to")
    assert @grant.reload.pending?

    post session_path, params: {
      email: identities(:owner).email,
      password: "password",
      return_to: query.fetch("return_to"),
    }

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    follow_redirect!
    assert_response :success
    assert @grant.reload.pending?
  end

  test "switching the signed-in human preserves context and resolves their own Agent profile" do
    verify
    get oauth_device_grant_path(@grant.public_id)
    assert_select "form[action=?]", session_path do
      assert_select "input[type=hidden][name='return_to'][value=?]",
        oauth_device_grant_path(@grant.public_id)
    end

    delete session_path, params: { return_to: oauth_device_grant_path(@grant.public_id) }
    assert_redirected_to new_session_path(return_to: oauth_device_grant_path(@grant.public_id))

    post session_path, params: {
      email: identities(:member).email,
      password: "password",
      return_to: oauth_device_grant_path(@grant.public_id),
    }

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    follow_redirect!
    assert_response :success
    assert_select "p", text: /Connect only when it matches exactly/
    assert_select "input[type=submit][value=?]", "Connect"
    assert @grant.reload.pending?
  end

  # The combined grant's page (r-modes M2; crit-product S-3) is branch A's
  # page plus ONE facts row in the page's own words: no scope block, no
  # runner heading, no browser precondition for the runner half. The settled
  # page says the same sentence while the program finishes connecting.
  test "a combined grant renders the agent page with one runner sentence and no scope block" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      agent_identifier: "rho",
      agent_display_name: "rho",
      requested_executor_display_name: "rho on laptop",
      runner_identifier: "rho",
      runner_display_name: "rho on laptop"
    ).authorization
    verify
    get oauth_device_grant_path(@grant.public_id)

    assert_response :success
    assert_select "h1", text: "Connect agent program"
    assert_select "h2", text: "Agent program"
    assert_select "p", text: "Also"
    assert_select "p", text: "Also runs as a runner on that machine — it can read, write and run " \
      "commands there — private to the Agent Profiles you manage."
    assert_select "fieldset", count: 0
    assert_select "input[name='connection[account_wide]']", count: 0
    assert_select "input[name='connection[expected_live_runner]']", count: 0
    assert_select "body", text: /rho on laptop/, count: 0
    assert_select "main#main" do
      assert_select "select, input[type=radio], input[type=checkbox]", count: 0
    end

    post oauth_device_grant_connection_path(@grant.public_id)

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.connected", subject: "agent program"), flash[:notice]
    follow_redirect!
    assert_select "p", text: "Connection ready. Waiting for the agent program to finish connecting.", count: 1
    assert_select "[role=alert]", count: 0
    assert_select "section[aria-label=?] footer", "Connection status" do
      assert_select "input[type=submit][value=?]", "Cancel connection"
      assert_select "a[href=?]", oauth_device_path, text: "Back to code entry"
    end
    assert_select "p", text: /Also runs as a runner on that machine/
    assert_select "p", text: /private to the Agent Profiles you manage/
    assert_predicate @grant.reload, :connected?
    assert_predicate @grant, :selects_user_private?
  end

  test "an agent-only grant's page carries no runner sentence" do
    verify
    get oauth_device_grant_path(@grant.public_id)

    assert_select "p", text: /Also runs as a runner/, count: 0
    post oauth_device_grant_connection_path(@grant.public_id)
    follow_redirect!
    assert_select "p", text: /Also runs as a runner/, count: 0
  end

  # One ceremony, one word: a grant confirmed under the runner wording must not be announced as an
  # agent program the moment the button is clicked — the flash derives its subject from the grant,
  # like every page in the ceremony does.
  test "connecting and canceling a runner grant speak the runner's name" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "workshop-install",
      runner_display_name: "Workshop laptop"
    ).authorization
    verify
    get oauth_device_grant_path(@grant.public_id)
    assert_select "[role=alert]", text: /replaces the old device immediately/
    assert_select "[role=alert]", text: /work already running there cannot move/i

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.connected", subject: "runner"), flash[:notice]
    refute_includes flash[:notice], "agent program"

    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "workshop-install-2",
      runner_display_name: "Workshop laptop"
    ).authorization
    verify
    post oauth_device_grant_cancellation_path(@grant.public_id)

    assert_equal I18n.t("oauth.device.canceled", subject: "runner"), flash[:notice]
    refute_includes flash[:notice], "agent program"
  end

  test "an administrator chooses Runner scope in the browser and unchecked stays private" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "workshop-install",
      runner_display_name: "Workshop laptop"
    ).authorization
    verify

    get oauth_device_grant_path(@grant.public_id)
    assert_select "fieldset" do
      assert_select "legend", text: "Assignment scope"
    end
    assert_select "input[type=checkbox][name=?]", "connection[account_wide]" do |checkboxes|
      assert_not checkboxes.first.has_attribute?("checked")
    end
    assert_select(
      "input[type=hidden][name='connection[expected_live_runner]']" \
        "[value='#{DeviceAuthorizations::Connect::ABSENT_LIVE_RUNNER}']"
    )
    assert_select "label", text: /Make this runner available account-wide/
    assert_select "body", text: /workshop-install/, count: 0

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params

    assert_predicate @grant.reload, :selects_user_private?
    sign_out
    sign_in_as users(:member)
    get oauth_device_grant_path(@grant.public_id)

    assert_response :success
    assert_select "p", text: /private to Agent Profiles managed by the member who connected it/
    assert_select "body", text: /Agent Profiles you manage/, count: 0
  end

  test "an administrator can explicitly connect an account-wide Runner" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "farm-install",
      runner_display_name: "Farm"
    ).authorization
    verify

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params(account_wide: true)

    assert_predicate @grant.reload, :selects_account_wide?
    follow_redirect!
    assert_select "p", text: /available account-wide/
  end

  test "an existing Runner shows its fixed scope and no scope control" do
    existing = connect_runner(
      manager: users(:owner),
      runner_identifier: "fixed-browser-scope",
      assignment_scope: :account_wide
    ).executor_access_token.task_executor
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: existing.runner_identifier,
      runner_display_name: "Replacement device"
    ).authorization
    verify

    get oauth_device_grant_path(@grant.public_id)

    assert_select "input[name='connection[account_wide]']", count: 0
    assert_select(
      "input[type=hidden][name='connection[expected_live_runner]']" \
        "[value='#{existing.public_id}']"
    )
    assert_select ".badge", text: "Account-wide"
    assert_select "p", text: /Reconnecting keeps this registration's existing scope/

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params(expected: existing.public_id)
    assert_predicate @grant.reload, :selects_account_wide?

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params(expected: existing.public_id)
    assert_equal I18n.t("oauth.device.connected", subject: "runner"), flash[:notice]
    assert_nil flash[:alert]

    result = DeviceAuthorizations::Consume.call(authorization: @grant)
    assert_equal :minted, result.outcome
    assert_equal existing, result.executor_access_token.task_executor
    assert_predicate existing.reload, :account_wide?
  end

  test "a live Runner revoked after the page rendered cannot silently become a fresh private registration" do
    existing = connect_runner(
      manager: users(:owner),
      runner_identifier: "revoked-after-runner-page",
      assignment_scope: :account_wide
    ).executor_access_token.task_executor
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: existing.runner_identifier,
      runner_display_name: "Replacement device"
    ).authorization
    verify
    get oauth_device_grant_path(@grant.public_id)
    assert_select "input[name='connection[account_wide]']", count: 0

    existing.revoke
    assert_no_difference -> { TaskExecutor.count } do
      post oauth_device_grant_connection_path(@grant.public_id),
        params: runner_connection_params(expected: existing.public_id)
    end

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.runner_registration_changed"), flash[:alert]
    assert_predicate @grant.reload, :pending?
    assert_nil @grant.selected_assignment_scope

    follow_redirect!
    assert_select "input[name='connection[account_wide]']", count: 1
    assert_select(
      "input[name='connection[expected_live_runner]']" \
        "[value='#{DeviceAuthorizations::Connect::ABSENT_LIVE_RUNNER}']"
    )
  end

  test "a Runner registered after an absent page rendered cannot consume that page's scope choice" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "registered-after-runner-page",
      runner_display_name: "Replacement device"
    ).authorization
    verify
    get oauth_device_grant_path(@grant.public_id)
    assert_select "input[name='connection[account_wide]']", count: 1

    existing = connect_runner(
      manager: users(:owner),
      runner_identifier: @grant.runner_identifier,
      assignment_scope: :account_wide
    ).executor_access_token.task_executor
    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.runner_registration_changed"), flash[:alert]
    assert_predicate @grant.reload, :pending?
    assert_nil @grant.selected_assignment_scope

    follow_redirect!
    assert_select "input[name='connection[account_wide]']", count: 0
    assert_select ".badge", text: "Account-wide"
    assert_select(
      "input[name='connection[expected_live_runner]']" \
        "[value='#{existing.public_id}']"
    )
  end

  test "an ordinary member cannot forge account-wide Runner scope" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "farm-install",
      runner_display_name: "Farm"
    ).authorization
    sign_out
    sign_in_as users(:member)
    verify

    get oauth_device_grant_path(@grant.public_id)
    assert_select "input[name='connection[account_wide]']", count: 0

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params(account_wide: true)

    assert_equal I18n.t("oauth.device.administrator_required"), flash[:alert]
    assert_predicate @grant.reload, :pending?
    assert_nil @grant.selected_assignment_scope
  end

  test "repeating Runner Connect with the same selected scope is idempotent" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "farm-install",
      runner_display_name: "Farm"
    ).authorization
    verify

    2.times do
      post oauth_device_grant_connection_path(@grant.public_id),
        params: runner_connection_params(account_wide: true)

      assert_redirected_to oauth_device_grant_path(@grant.public_id)
      assert_equal I18n.t("oauth.device.connected", subject: "runner"), flash[:notice]
      assert_nil flash[:alert]
    end
    assert_predicate @grant.reload, :selects_account_wide?
  end

  test "repeating Runner Connect with a different selected scope is unavailable" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "workshop-install",
      runner_display_name: "Workshop laptop"
    ).authorization
    verify

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params
    assert_predicate @grant.reload, :selects_user_private?

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params(account_wide: true)

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.connection_unavailable", subject: "runner"), flash[:alert]
    assert_predicate @grant.reload, :selects_user_private?
  end

  test "a repeated Connect from a superseded Human generation is unavailable" do
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: "superseded-browser-generation",
      runner_display_name: "Workshop laptop"
    ).authorization
    verify
    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params
    frozen_generation = @grant.reload.connected_by_authority_generation
    @grant.update_column(
      :connected_by_authority_generation,
      frozen_generation - 1
    )

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.connection_unavailable", subject: "runner"),
      flash[:alert]
    assert_nil flash[:notice]
  end

  test "a Runner re-pair still finishing Human shutdown asks the manager to retry" do
    connection = connect_runner(
      manager: users(:owner),
      runner_identifier: "browser-shutdown-pending"
    )
    runner = connection.executor_access_token.task_executor
    users(:owner).update_column(
      :managed_resource_shutdown_generation,
      users(:owner).managed_resource_shutdown_generation + 1
    )
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      runner_identifier: runner.runner_identifier,
      runner_display_name: "Workshop laptop"
    ).authorization
    verify

    post oauth_device_grant_connection_path(@grant.public_id),
      params: runner_connection_params(expected: runner.public_id)

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.shutdown_pending", subject: "runner"),
      flash[:alert]
    assert_predicate @grant.reload, :pending?
  end

  test "canceling shares no credential" do
    verify

    assert_no_difference -> { AccessToken.count } do
      post oauth_device_grant_cancellation_path(@grant.public_id)
    end

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.canceled", subject: "agent program"), flash[:notice]
    assert @grant.reload.canceled?
    follow_redirect!
    assert_select "p", text: "This connection was canceled. No credential was shared with the agent program.", count: 1
    assert_select "[role=alert]", count: 0
    assert_select "input[type=submit][value=?]", "Cancel connection", count: 0
  end

  test "commands on a grant this browser never verified are not found" do
    post oauth_device_grant_connection_path(@grant.public_id)
    assert_redirected_to oauth_device_path
    assert_equal I18n.t("oauth.device.unknown_grant"), flash[:alert]
    assert @grant.reload.pending?

    post oauth_device_grant_cancellation_path(@grant.public_id)
    assert_redirected_to oauth_device_path
    assert_equal I18n.t("oauth.device.unknown_grant"), flash[:alert]
    assert @grant.reload.pending?
  end

  test "a stale command renders the terminal state instead of repeating the connection" do
    verify
    post oauth_device_grant_cancellation_path(@grant.public_id)
    assert @grant.reload.canceled?

    post oauth_device_grant_connection_path(@grant.public_id)

    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal I18n.t("oauth.device.connection_unavailable", subject: "agent program"), flash[:alert]
    follow_redirect!
    assert_select "[role=alert]", text: I18n.t("oauth.device.connection_unavailable", subject: "agent program"), count: 1
    assert_select "section[aria-label=?] [role=alert]", "Connection status", count: 1
  end

  test "an administrator connects through the same per-human mapping as an ordinary member" do
    assert_equal :role_changed, users(:member).change_role(to: :admin)
    @grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      agent_identifier: users(:agent).agent_identifier,
      agent_display_name: "Administrators do not adopt",
      requested_executor_display_name: "App",
    ).authorization

    sign_out
    sign_in_as users(:member)
    verify
    get oauth_device_grant_path(@grant.public_id)

    assert_select "input[type=submit][value=?]", "Connect"
    assert_select "body", text: /Fixture Agent/, count: 0

    assert_no_difference -> { User.count } do
      post oauth_device_grant_connection_path(@grant.public_id)
    end
    assert_nil @grant.reload.user

    assert_difference -> { User.where(kind: :agent).count }, 1 do
      assert_equal :minted, DeviceAuthorizations::Consume.call(authorization: @grant).outcome
    end
    assert_equal users(:member), @grant.reload.user.steward
    assert_not_equal users(:agent), @grant.user
  end

  private

    def runner_connection_params(
      expected: DeviceAuthorizations::Connect::ABSENT_LIVE_RUNNER,
      account_wide: false
    )
      connection = { expected_live_runner: expected }
      connection[:account_wide] = "1" if account_wide
      { connection: connection }
    end

    def verify
      post oauth_device_verification_path, params: {
        verification: { user_code: @grant.formatted_user_code },
      }
    end

    def assert_only_return_to
      assert_select "input[type=hidden][name=return_to][value=?]",
        oauth_device_grant_path(@grant.public_id)
      assert_select "input[name]:not([name=authenticity_token]):not([name=return_to])", count: 0
    end
end
