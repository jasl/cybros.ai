require "test_helper"

# Agent User administration is deliberately narrow: membership visibility,
# steward reassignment, and remove/restore. Connection, executor, and
# credential ownership remain with the steward and agent program.
class Admin::AgentUsersTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
    @agent = users(:agent)
  end

  test "admin-only Agent User and user-bound executor routes do not exist" do
    routes = Rails.application.routes

    assert_raises(ActionController::RoutingError) do
      routes.recognize_path("/admin/agent_members/new", method: :get)
    end
    assert_raises(ActionController::RoutingError) do
      routes.recognize_path("/admin/executors", method: :get)
    end
  end

  test "Users lists only people and Agents have a separate directory" do
    get admin_users_path
    assert_select "h1", text: "Users"
    assert_select "[data-user-id=?]", users(:owner).public_id
    assert_select "[data-user-id=?]", @agent.public_id, count: 0
    assert_select "a[href=?]", admin_agents_path

    get admin_agents_path
    assert_select "h1", text: "Agents"
    assert_select "[data-agent-id=?]", @agent.public_id
    assert_select "[data-agent-id=?]", users(:owner).public_id, count: 0
    assert_select "th", text: "Email", count: 0
    assert_select "th", text: "Role", count: 0

    get admin_user_path(@agent)
    assert_response :not_found
    get admin_agent_path(users(:owner))
    assert_response :not_found
    get admin_agent_path(users(:system))
    assert_response :not_found
  end

  test "the Agent User page exposes only identity, steward, and lifecycle administration" do
    get admin_agent_path(@agent.public_id)

    assert_response :success
    assert_select "body", text: /#{Regexp.escape(@agent.agent_identifier)}/, count: 0
    assert_select "dd", text: /Owner/
    assert_select "a[href=?]", admin_agent_steward_path(@agent.public_id), text: /Change manager/
    assert_select "select[name='steward[steward_public_id]']", count: 0
    assert_select "form[action=?]", admin_agent_removal_path(@agent.public_id)
    assert_select "form[action=?]", admin_user_suspension_path(@agent.public_id), count: 0
    assert_select "form[action=?]", admin_user_role_path(@agent.public_id), count: 0
    assert_select "h2", text: "Credentials", count: 0
    assert_select "p", text: /Availability/, count: 0
    assert_select "a", text: /Register an executor/, count: 0
  end

  test "the Agent directory filters name and status without including people" do
    @agent.update!(handle: "archived-assistant")
    @agent.remove

    get admin_agents_path, params: { query: "ARCHIVED-ASSISTANT", status: "removed" }

    assert_response :success
    assert_select "[data-agent-id]", count: 1
    assert_select "[data-agent-id=?]", @agent.public_id
    assert_select "a[href=?]", admin_agent_path(@agent)
    assert_select "select[name=status] option[selected][value=removed]"

    get admin_agents_path, params: { query: "archived-assistant", status: "active" }
    assert_select "[data-agent-id]", count: 0
    assert_select "body", text: /No matching Agents/
  end

  test "the steward selection page is addressable and offers active human members only" do
    users(:member).suspend

    get admin_agent_steward_path(@agent.public_id)

    assert_response :success
    assert_select "h1", text: "Change manager"
    assert_select "form[action=?][method='get']", admin_agent_steward_path(@agent.public_id)
    assert_select "input[name='query'][maxlength='100']"
    assert_select "[data-steward-candidate-id=?]", users(:owner).public_id
    assert_select "[data-steward-candidate-id=?]", users(:member).public_id, count: 0
  end

  test "the steward selection page offers members who already steward other Agents" do
    other_profile = create_agent_member(
      steward: users(:member),
      agent_identifier: "other-installation",
      display_name: "Other profile"
    )
    assert_equal :removed, other_profile.remove

    get admin_agent_steward_path(@agent.public_id)

    assert_response :success
    assert_select "[data-steward-candidate-id=?]", users(:owner).public_id
    assert_select "[data-steward-candidate-id=?]", users(:member).public_id
  end

  test "steward candidate search is bounded, paginated, and retains its query" do
    candidates = 26.times.map { |index| create_human_candidate(index) }

    get admin_agent_steward_path(@agent.public_id), params: { query: "Candidate" }

    assert_response :success
    assert_select "[data-steward-candidate-id]", count: 25
    assert_select "nav[aria-label='Manager candidates'] a[href*='page=2'][href*='query=Candidate']"

    get admin_agent_steward_path(@agent.public_id), params: { query: "Candidate", page: 2 }

    assert_response :success
    assert_select "[data-steward-candidate-id]", count: 1

    get admin_agent_steward_path(@agent.public_id), params: { query: candidates.last.email }

    assert_response :success
    assert_select "[data-steward-candidate-id=?]", candidates.last.public_id
    assert_select "[data-steward-candidate-id]", count: 1
  end

  test "the steward selection URL enforces admin and Agent target boundaries" do
    get admin_agent_steward_path(users(:member).public_id)
    assert_response :not_found

    get admin_agent_steward_path(SecureRandom.uuid_v7)
    assert_response :not_found

    sign_out
    sign_in_as users(:member)
    get admin_agent_steward_path(@agent.public_id)
    assert_response :forbidden
  end

  test "an inactive steward warning preserves the executor transport distinction" do
    assert_equal :changed, @agent.change_steward(to: users(:member))
    users(:member).suspend

    get admin_agent_path(@agent.public_id)

    assert_select "p", text: /manager is inactive/
    assert_select "p", text: /Work already in progress may still report its result/
    assert_select "p", text: /cannot authenticate/, count: 0
  end

  test "steward reassignment round-trips and rejects ineligible targets" do
    users(:member).suspend
    patch admin_agent_steward_path(@agent.public_id), params: { steward: { steward_public_id: users(:member).public_id } }
    assert_equal I18n.t("admin.agents.invalid_steward"), flash[:alert]
    assert_equal users(:owner), @agent.reload.steward

    users(:member).reload.reactivate
    patch admin_agent_steward_path(@agent.public_id), params: { steward: { steward_public_id: users(:member).public_id } }
    assert_equal I18n.t("admin.agents.steward_changed"), flash[:notice]
    assert_equal users(:member), @agent.reload.steward

    patch admin_agent_steward_path(users(:owner).public_id), params: { steward: { steward_public_id: users(:member).public_id } }
    assert_response :not_found
  end

  test "steward reassignment reports a source shutdown episode distinctly" do
    assert_equal :changed, @agent.change_steward(to: users(:member))
    assert_equal :removed, users(:member).remove

    patch admin_agent_steward_path(@agent.public_id),
      params: { steward: { steward_public_id: users(:owner).public_id } }

    assert_equal I18n.t("admin.agents.steward_shutdown_pending"), flash[:alert]
    assert_equal users(:member), @agent.reload.steward
  end

  test "the steward command refuses a human target with the agent-only guard" do
    # The owner is not administrable by itself; use a human member target.
    patch admin_agent_steward_path(users(:member).public_id), params: { steward: { steward_public_id: users(:owner).public_id } }
    assert_response :not_found
  end

  test "the human role command cannot promote an Agent User" do
    patch admin_user_role_path(@agent.public_id), params: { role: { role: "admin" } }

    assert_response :not_found
    assert_equal "member", @agent.reload.role
  end

  test "the human activation command cannot operate on an Agent User" do
    post admin_user_activation_path(@agent.public_id)

    assert_response :not_found
    assert_predicate @agent.reload, :active?
  end

  test "Agent remove and restore flashes explain the credential cut and reconnect" do
    post admin_agent_removal_path(@agent.public_id)

    assert_equal I18n.t("admin.agents.removed"), flash[:notice]
    assert_match(/access and keys are revoked immediately/, flash[:notice])

    post admin_agent_restoration_path(@agent.public_id)

    assert_equal I18n.t("admin.agents.restored"), flash[:notice]
    assert_match(/Old keys remain invalid/, flash[:notice])
    assert_match(/reconnect the application to resume access/, flash[:notice])
  end

  test "Agent restore reports a pending steward shutdown distinctly" do
    assert_equal :changed, @agent.change_steward(to: users(:member))
    assert_equal :removed, @agent.remove
    assert_equal :removed, users(:member).remove

    post admin_agent_restoration_path(@agent.public_id)

    assert_equal I18n.t("admin.agents.restore_shutdown_pending"),
      flash[:alert]
    assert_predicate @agent.reload, :removed?
  end

  test "a removed Agent can be reassigned before its new steward ends the retained registration" do
    connected = connect_agent_session(
      steward: users(:owner),
      agent_identifier: "removed-reassignment",
      display_name: "Removed reassignment",
      device_name: "Old device"
    )
    agent = connected.access_token.user
    address = connected.executor_access_token.executor

    post admin_agent_removal_path(agent.public_id)
    assert_predicate agent.reload, :removed?
    assert_predicate address.reload, :active?

    get admin_agent_path(agent.public_id)
    assert_select "a[href=?]", admin_agent_steward_path(agent.public_id), text: /Change manager/

    get admin_agent_steward_path(agent.public_id)
    assert_response :success
    assert_select "body", text: /Agent will stay removed/

    patch admin_agent_steward_path(agent.public_id),
      params: { steward: { steward_public_id: users(:member).public_id } }

    assert_equal users(:member), agent.reload.steward
    assert_predicate agent, :removed?
    assert_predicate address.reload, :active?, "reassignment retains the address whose old credentials were already fenced"

    sign_out
    sign_in_as users(:member)
    delete agent_credentials_path(agent.public_id)

    assert_redirected_to agent_path(agent.public_id)
    assert_predicate address.reload, :revoked?
    assert_predicate agent.reload, :removed?
  end

  private

    def create_human_candidate(index)
      identity = accounts(:cybros).identities.create!(
        email: format("candidate-%02d@example.com", index),
        password_digest: identities(:member).password_digest
      )
      accounts(:cybros).users.create!(
        kind: :human,
        role: :member,
        identity: identity,
        display_name: format("Candidate %02d", index)
      )
    end
end
