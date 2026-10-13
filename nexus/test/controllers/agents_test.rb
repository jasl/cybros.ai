require "test_helper"

# The steward's own management plane: a human manages the agent profiles they steward and nothing
# else. Administrators reach none of this — member-owned executors and credentials stay on their
# owning member's flows.
class AgentsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:owner)
    @member = users(:member)
    sign_in_as @owner
  end

  test "the index lists only the signed-in human's stewarded profiles" do
    mine = connect_agent_session(steward: @owner, agent_identifier: "mine",
      display_name: "My program").access_token.user
    theirs = create_agent_member(steward: @member, display_name: "Their program",
      agent_identifier: "theirs")

    get agents_path

    assert_response :success
    assert_select "title", text: /My agents/
    assert_select "tr[data-agent-id='#{mine.public_id}']" do
      assert_select "a[href=?]", agent_path(mine.public_id), text: "Manage"
    end
    assert_select "tr[data-agent-id='#{theirs.public_id}']", count: 0
    assert_select "a[href=?]", oauth_device_path, text: "Connect agent"
  end

  test "an epoch-fenced live lineage does not imply credential readiness" do
    connected = connect_agent_session(
      steward: @member,
      agent_identifier: "fenced",
      display_name: "Fenced program"
    )
    profile = connected.access_token.user
    address = connected.executor_access_token.task_executor
    family = connected.access_token.refresh_token_family

    assert_equal :removed, @member.remove
    assert_equal :converged, address.converge_human_shutdown(
      expected_human_id: @member.id,
      expected_generation: @member.managed_resource_shutdown_generation,
      expected_applied_generation: address.applied_human_shutdown_generation
    )
    assert_equal :restored, @member.restore
    sign_out
    sign_in_as @member

    assert_nil family.reload.revoked_at,
      "family marker convergence is intentionally asynchronous"
    assert_not_equal family.credential_epoch, address.reload.credential_epoch
    assert_equal :no_credential,
      TaskExecutor.credential_readiness_for([address]).fetch(address.id)

    get agents_path

    assert_response :success
    assert_select "tr[data-agent-id='#{profile.public_id}']", text: /Registered/
    assert_select "tr[data-agent-id='#{profile.public_id}']", text: /No credential/
    assert_select "tr[data-agent-id='#{profile.public_id}']", text: /Connected/, count: 0

    get agent_path(profile.public_id)

    assert_response :success
    assert_select "[data-address-id='#{address.public_id}']" do
      assert_select ".badge", text: "No credential"
      assert_select "button", text: "Revoke credentials"
    end

    delete agent_credentials_path(profile.public_id)

    assert_redirected_to agent_path(profile.public_id)
    assert_predicate address.reload, :revoked?
  end

  test "an unexpired access token keeps readiness when its refresh lineage lapses" do
    connected = connect_agent_session(
      steward: @owner,
      agent_identifier: "access-ready",
      display_name: "Access-ready program"
    )
    profile = connected.access_token.user
    address = connected.executor_access_token.task_executor
    family = connected.access_token.refresh_token_family
    family.update!(
      last_used_at: Time.current - RefreshTokenFamily::INACTIVITY_WINDOW - 1.minute
    )

    assert_not family.rotation_acceptable?
    assert_equal :ready,
      TaskExecutor.credential_readiness_for([address]).fetch(address.id)

    get agents_path

    assert_response :success
    assert_select "tr[data-agent-id='#{profile.public_id}']", text: /Ready/
  end

  test "another steward's profile is not found rather than forbidden" do
    theirs = create_agent_member(steward: @member, agent_identifier: "theirs")

    get agent_path(theirs.public_id)
    assert_response :not_found
  end

  test "the show page shows the profile's one address with its device label" do
    connect_agent_session(steward: @owner, agent_identifier: "shared", device_name: "Desktop")
    laptop = connect_agent_session(steward: @owner, agent_identifier: "shared", device_name: "Laptop")
    profile = laptop.access_token.user
    address = laptop.executor_access_token.task_executor

    get agent_path(profile.public_id)

    assert_response :success
    assert_select "[data-address-id='#{address.public_id}']"
    assert_select "[data-address-id]", 1, "an Agent has one address, so the page shows one"
    assert_select "body", text: /Laptop/
    assert_select "body",
      text: /Connecting a replacement device.*re-pairs that address/m
    assert_select "body", text: /does not mean the program\s+is online/m
    assert_select "button[data-turbo-confirm]", text: "Revoke credentials" do |buttons|
      assert_equal(
        "Revoke credentials for Laptop? It ends this registration and invalidates any current credentials immediately. The profile and its data stay; connecting again creates a new registration.",
        buttons.sole["data-turbo-confirm"]
      )
    end
    assert_select "body", text: /Program ID/, count: 0
    assert_select "code", text: profile.agent_identifier, count: 0
  end

  # The address's observability history outlives the steward-revoked connection, so the page must
  # still say when it was last seen — that is the state where the question is most likely to be
  # asked. The revoke clears the presence mark, so the word is "Offline" beside the sample, never
  # "Online" and never "Not yet seen".
  test "a steward-revoked connection still reports when its address was last seen" do
    connected = connect_agent_session(steward: @owner, agent_identifier: "shared", device_name: "Desktop")
    profile = connected.access_token.user
    address = connected.executor_access_token.task_executor
    AccessToken.authenticate_executor_token(connected.executor_access_secret)
    last_seen_at = address.reload.last_seen_at
    assert_not_nil last_seen_at
    address.mark_connected("socket-open-at-revoke")

    delete agent_credentials_path(profile.public_id)
    assert_redirected_to agent_path(profile.public_id)
    assert_predicate address.reload, :revoked?

    get agent_path(profile.public_id)

    assert_response :success
    assert_select "p", text: "Not registered"
    assert_select "span[title='#{last_seen_at.iso8601}']", text: /Offline · last seen .* ago/
    assert_select "body", text: /Online|Not yet seen/, count: 0
  end

  # PRESENCE (r-modes M4): the live, pong-verified executor socket, rendered
  # through one helper over Nexus::Presence — display, never a gate.
  test "an address with an open executor socket reads Online" do
    NexusServer.register
    connected = connect_agent_session(steward: @owner, agent_identifier: "live", device_name: "Desktop")
    profile = connected.access_token.user
    address = connected.executor_access_token.task_executor
    AccessToken.authenticate_executor_token(connected.executor_access_secret)
    address.mark_connected("socket-1")

    get agent_path(profile.public_id)

    assert_response :success
    assert_select "span[title='#{address.reload.last_seen_at.iso8601}']", text: /Online/
    assert_select "body", text: /Offline|Not yet seen/, count: 0
  end

  test "a profile whose address was never used says not yet seen rather than guessing" do
    profile = connect_agent_session(steward: @owner, agent_identifier: "fresh").access_token.user

    get agent_path(profile.public_id)

    assert_response :success
    assert_select "body", text: /Not yet seen/
    assert_select "body", text: /Online|Offline/, count: 0
  end

  test "a profile that has no address says so rather than showing an empty table" do
    profile = users(:agent)
    profile.refresh_token_families.live.each(&:revoke)
    TaskExecutor.address_for(profile)&.revoke

    get agent_path(profile.public_id)

    assert_response :success
    assert_select "[data-address-id]", 0
    assert_select "p", text: "Not registered"
  end

  test "revoking credentials ends the connection and its address" do
    connected = connect_agent_session(steward: @owner, agent_identifier: "shared", device_name: "Desktop")
    profile = connected.access_token.user
    address = connected.executor_access_token.task_executor

    delete agent_credentials_path(profile.public_id)

    assert_redirected_to agent_path(profile.public_id)
    assert_equal I18n.t("agents.credentials.destroy.revoked"), flash[:notice]
    assert_empty profile.refresh_token_families.live
    assert_nil AccessToken.authenticate_token(connected.access_secret)
    assert_predicate address.reload, :revoked?

    get agent_path(profile.public_id)
    assert_select "p", text: "Not registered"
  end

  # There is no verb for moving work between clients, because a profile has only one address to move
  # it between.
  test "no route offers a handoff" do
    helpers = Rails.application.routes.url_helpers

    assert_not helpers.respond_to?(:agent_handoff_path)
    assert_not helpers.respond_to?(:agent_session_path),
      "one connection needs one revoke verb, not a per-session one beside it"
  end

  test "the steward removes and restores their own profile" do
    profile = connect_agent_session(steward: @owner, agent_identifier: "mine").access_token.user

    get agent_path(profile.public_id)
    assert_response :success
    assert_select "form[action=?]", agent_removal_path(profile.public_id) do
      assert_select "button[data-turbo-confirm]", text: "Remove"
    end

    post agent_removal_path(profile.public_id)
    assert_predicate profile.reload, :removed?
    assert_equal I18n.t("agents.removals.create.removed"), flash[:notice]

    get agent_path(profile.public_id)
    assert_response :success
    assert_select "form[action=?]", agent_restoration_path(profile.public_id) do
      assert_select "button", text: "Restore"
    end

    post agent_restoration_path(profile.public_id)
    assert_predicate profile.reload, :active?
    assert_equal I18n.t("agents.restorations.create.restored"), flash[:notice]
  end

  # THE AGENT'S HANDLE: the kernel assigned one at creation; the steward changes it here, the
  # smallest door the management surface had room for — the show page names it beside the profile's
  # facts.
  test "the steward changes their own profile's handle; a taken one re-renders with the error" do
    profile = create_agent_member(steward: @owner, agent_identifier: "mine", display_name: "Mine")

    get agent_path(profile.public_id)
    assert_response :success
    assert_select "input[name='handle[handle]'][value=?]", profile.handle
    assert_select "form[action=?]", agent_handle_path(profile.public_id)

    patch agent_handle_path(profile.public_id), params: { handle: { handle: "Lark" } }
    assert_redirected_to agent_path(profile.public_id)
    assert_equal "lark", profile.reload.handle
    assert_equal I18n.t("agents.handles.update.updated"), flash[:notice]

    patch agent_handle_path(profile.public_id), params: { handle: { handle: @member.handle } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /taken/
    assert_equal "lark", profile.reload.handle
  end

  test "a refused handle change re-renders the show page over the same facts: the address stays on the page" do
    connected = connect_agent_session(steward: @owner, agent_identifier: "mine", device_name: "Desktop")
    profile = connected.access_token.user
    address = connected.executor_access_token.task_executor

    patch agent_handle_path(profile.public_id), params: { handle: { handle: @member.handle } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /taken/
    assert_select "[data-address-id='#{address.public_id}']", 1, "the refused change re-renders over the show page's facts"
    assert_select "button", text: "Revoke credentials"
  end

  test "commands on another steward's profile are not found" do
    theirs = create_agent_member(steward: @member, agent_identifier: "theirs")
    patch agent_handle_path(theirs.public_id), params: { handle: { handle: "lark" } }
    assert_response :not_found

    delete agent_credentials_path(theirs.public_id)
    assert_response :not_found
    post agent_removal_path(theirs.public_id)
    assert_response :not_found
    assert_predicate theirs.reload, :active?
  end

  test "the surface requires an authenticated human" do
    sign_out
    get agents_path
    assert_redirected_to new_session_path(return_to: agents_path)
  end

  # THE COOLDOWN at the steward's door.
  test "the steward's door refuses a handle another member released within 14 days, naming the cooldown; the profile's own previous name is free at once" do
    profile = create_agent_member(steward: @owner, agent_identifier: "mine", display_name: "Mine")
    original = profile.handle
    travel_to(3.days.ago) { @member.update!(handle: "someone") }

    patch agent_handle_path(profile.public_id), params: { handle: { handle: "member" } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /14 days/
    assert_equal original, profile.reload.handle

    patch agent_handle_path(profile.public_id), params: { handle: { handle: "lark-x" } }
    assert_redirected_to agent_path(profile.public_id)
    assert_equal({ "user_public_id" => profile.public_id, "old" => original, "new" => "lark-x" },
      profile.conversation_event_items.sole.payload, "the steward's door narrates handle_changed on the member")
    patch agent_handle_path(profile.public_id), params: { handle: { handle: original } }
    assert_redirected_to agent_path(profile.public_id)
    assert_equal original, profile.reload.handle
    assert_equal "lark-x", profile.previous_handle
  end
end

# THE HUMAN'S PAGE AND THE NAMED DEFINITIONS: the rows a paired program declared list beside it with
# their declarer and no address; show renders with no address; the parent's removal takes its
# instance rows and leaves its published one; the parent's restoration restores none.
class AgentsNamedDefinitionsTest < ActionDispatch::IntegrationTest
  CONFIGURATION = {
    tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: "default",
    prompt_template: nil, compaction_policy: nil, default_model: nil,
  }.freeze

  setup do
    @owner = users(:owner)
    sign_in_as @owner
    @parent = connect_agent_session(steward: @owner, agent_identifier: "rho.parent", display_name: "My rho")
      .access_token.user
    @reviewer = declare("reviewer", "instance")
    @published = declare("docs", "steward")
  end

  def declare(name, scope)
    Users::DeclareNamedDefinition.call(caller: @parent, name: name, scope: scope,
      description: "#{name.capitalize} does its job.", configuration: CONFIGURATION).user
  end

  test "the index lists the named rows with their declarer and scope, not registered, no credential" do
    get agents_path

    assert_response :success
    assert_select "tr[data-agent-id='#{@reviewer.public_id}']" do
      assert_select "td[data-defined-by]", text: /My rho\s+instance/
      assert_select "td", text: /Reviewer does its job\./
      assert_select "span", text: "Not registered"
      assert_select "span", text: I18n.t("executors.credential_readiness.no_credential")
    end
    assert_select "tr[data-agent-id='#{@published.public_id}'] td[data-defined-by]", text: /My rho\s+steward/
    assert_select "tr[data-agent-id='#{@parent.public_id}'] td[data-defined-by]", text: "—"
  end

  test "show renders a named row with no address" do
    get agent_path(@reviewer.public_id)

    assert_response :success
    assert_select "h1", text: "reviewer"
    assert_select "dd", text: "My rho (instance)"
    assert_select "dd", text: "Reviewer does its job."
    assert_select "p", text: "Not registered"
    assert_select "[data-address-id]", count: 0
  end

  test "removing the parent removes its instance rows and leaves the published one; restoring restores none" do
    post agent_removal_path(@parent.public_id)
    assert_redirected_to agent_path(@parent.public_id)
    assert_predicate @reviewer.reload, :removed?
    assert_predicate @published.reload, :active?

    post agent_restoration_path(@parent.public_id)
    assert_predicate @parent.reload, :active?
    assert_predicate @reviewer.reload, :removed?

    post agent_removal_path(@published.public_id)
    assert_predicate @published.reload, :removed?, "the human's page removes a published row like any stewarded profile"
  end
end
