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
      routes.recognize_path("/admin/task_executors", method: :get)
    end
  end

  test "members index badges agents and shows the em-dash email" do
    get admin_users_path
    assert_select "span.badge", text: /agent/
    assert_select "td", text: "—"
    assert_select "a", text: "Agents & executors", count: 0
  end

  test "the Agent User page exposes only identity, steward, and lifecycle administration" do
    get admin_user_path(@agent.public_id)

    assert_response :success
    assert_select "body", text: /#{Regexp.escape(@agent.agent_identifier)}/, count: 0
    assert_select "p", text: /Owner/
    assert_select "a[href=?]", admin_user_steward_path(@agent.public_id), text: /Reassign steward/
    assert_select "select[name='steward[steward_public_id]']", count: 0
    assert_select "form[action=?]", admin_user_removal_path(@agent.public_id)
    assert_select "form[action=?]", admin_user_suspension_path(@agent.public_id), count: 0
    assert_select "form[action=?]", admin_user_role_path(@agent.public_id), count: 0
    assert_select "h2", text: "Credentials", count: 0
    assert_select "p", text: /Availability/, count: 0
    assert_select "a", text: /Register an executor/, count: 0
  end

  test "the steward selection page is addressable and offers active human members only" do
    users(:member).suspend

    get admin_user_steward_path(@agent.public_id)

    assert_response :success
    assert_select "h1", text: "Reassign steward"
    assert_select "form[action=?][method='get']", admin_user_steward_path(@agent.public_id)
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

    get admin_user_steward_path(@agent.public_id)

    assert_response :success
    assert_select "[data-steward-candidate-id=?]", users(:owner).public_id
    assert_select "[data-steward-candidate-id=?]", users(:member).public_id
  end

  test "steward candidate search is bounded, paginated, and retains its query" do
    candidates = 26.times.map { |index| create_human_candidate(index) }

    get admin_user_steward_path(@agent.public_id), params: { query: "Candidate" }

    assert_response :success
    assert_select "[data-steward-candidate-id]", count: 25
    assert_select "nav[aria-label='Steward candidates pages'] a[href*='page=2'][href*='query=Candidate']"

    get admin_user_steward_path(@agent.public_id), params: { query: "Candidate", page: 2 }

    assert_response :success
    assert_select "[data-steward-candidate-id]", count: 1

    get admin_user_steward_path(@agent.public_id), params: { query: candidates.last.email }

    assert_response :success
    assert_select "[data-steward-candidate-id=?]", candidates.last.public_id
    assert_select "[data-steward-candidate-id]", count: 1
  end

  test "the steward selection URL enforces admin and Agent target boundaries" do
    get admin_user_steward_path(users(:member).public_id)
    assert_redirected_to admin_user_path(users(:member).public_id)
    assert_equal I18n.t("admin.users.not_agent"), flash[:alert]

    get admin_user_steward_path(SecureRandom.uuid_v7)
    assert_response :not_found

    sign_out
    sign_in_as users(:member)
    get admin_user_steward_path(@agent.public_id)
    assert_response :forbidden
  end

  test "an inactive steward warning preserves the executor transport distinction" do
    assert_equal :changed, @agent.change_steward(to: users(:member))
    users(:member).suspend

    get admin_user_path(@agent.public_id)

    assert_select "p", text: /member\/data access and new task admission are blocked/
    assert_select "p", text: /executor transport is not fenced/
    assert_select "p", text: /cannot authenticate/, count: 0
  end

  test "steward reassignment round-trips and rejects ineligible targets" do
    users(:member).suspend
    patch admin_user_steward_path(@agent.public_id), params: { steward: { steward_public_id: users(:member).public_id } }
    assert_equal I18n.t("admin.users.invalid_steward"), flash[:alert]
    assert_equal users(:owner), @agent.reload.steward

    users(:member).reload.reactivate
    patch admin_user_steward_path(@agent.public_id), params: { steward: { steward_public_id: users(:member).public_id } }
    assert_equal I18n.t("admin.users.steward_changed"), flash[:notice]
    assert_equal users(:member), @agent.reload.steward

    patch admin_user_steward_path(users(:owner).public_id), params: { steward: { steward_public_id: users(:member).public_id } }
    assert_equal I18n.t("admin.users.not_administrable"), flash[:alert]
  end

  test "steward reassignment reports a source shutdown episode distinctly" do
    assert_equal :changed, @agent.change_steward(to: users(:member))
    assert_equal :removed, users(:member).remove

    patch admin_user_steward_path(@agent.public_id),
      params: { steward: { steward_public_id: users(:owner).public_id } }

    assert_equal I18n.t("admin.users.steward_shutdown_pending"), flash[:alert]
    assert_equal users(:member), @agent.reload.steward
  end

  test "the steward command refuses a human target with the agent-only guard" do
    # The owner is not administrable by itself; use a human member target.
    patch admin_user_steward_path(users(:member).public_id), params: { steward: { steward_public_id: users(:owner).public_id } }
    assert_equal I18n.t("admin.users.not_agent"), flash[:alert]
  end

  test "the human role command cannot promote an Agent User" do
    patch admin_user_role_path(@agent.public_id), params: { role: { role: "admin" } }

    assert_equal I18n.t("admin.users.not_administrable"), flash[:alert]
    assert_equal "member", @agent.reload.role
  end

  test "the human activation command cannot operate on an Agent User" do
    post admin_user_activation_path(@agent.public_id)

    assert_equal I18n.t("admin.users.not_administrable"), flash[:alert]
    assert_predicate @agent.reload, :active?
  end

  test "Agent remove and restore flashes explain the credential cut and reconnect" do
    post admin_user_removal_path(@agent.public_id)

    assert_equal I18n.t("admin.users.agent_removed"), flash[:notice]
    assert_match(/access and credentials are revoked immediately/, flash[:notice])

    post admin_user_restoration_path(@agent.public_id)

    assert_equal I18n.t("admin.users.agent_restored"), flash[:notice]
    assert_match(/Old credentials remain invalid/, flash[:notice])
    assert_match(/reconnect the program to resume access/, flash[:notice])
  end

  test "Agent restore reports a pending steward shutdown distinctly" do
    assert_equal :changed, @agent.change_steward(to: users(:member))
    assert_equal :removed, @agent.remove
    assert_equal :removed, users(:member).remove

    post admin_user_restoration_path(@agent.public_id)

    assert_equal I18n.t("admin.users.agent_restore_shutdown_pending"),
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
    address = connected.executor_access_token.task_executor

    post admin_user_removal_path(agent.public_id)
    assert_predicate agent.reload, :removed?
    assert_predicate address.reload, :active?

    get admin_user_path(agent.public_id)
    assert_select "a[href=?]", admin_user_steward_path(agent.public_id), text: /Reassign steward/

    get admin_user_steward_path(agent.public_id)
    assert_response :success
    assert_select "body", text: /keeps the Agent removed/

    patch admin_user_steward_path(agent.public_id),
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
