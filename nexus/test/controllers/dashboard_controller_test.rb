require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @human = users(:member)
    sign_in_as @human
  end

  test "overview uses the authenticated identity and four management entries without analysis or authoring" do
    assert_no_queries_match(/FROM "identities".*LIMIT/) { get root_path }
    assert_response :success
    assert_select "nav[aria-label='Primary']" do
      {
        "Overview" => root_path, "Connect an Agent" => agent_connection_path,
        "Agents" => agents_path, "Workspaces" => workspaces_path,
        "Runners" => runners_path, "Settings" => settings_path,
      }.each { |label, path| assert_select "a[href=?]", path, text: label }
      ["/conversations", "/runs", "/schedules", "/conversations/new"].each do |path|
        assert_select "a[href=?]", path, count: 0
      end
    end
    assert_select "form[method=get]", count: 0
    assert_select "svg a", count: 0
    assert_select "a[href=?]", admin_model_providers_path, count: 0
    assert_select "a[href=?]", new_workspace_path
  end

  test "model configuration is shown only to an administrator when no model is available" do
    sign_out
    sign_in_as users(:owner)
    get root_path
    assert_response :success
    assert_select "nav[aria-label='Primary'] a[href=?]", admin_model_usage_path, text: "Administration"
    assert_select "a[href=?]", admin_model_providers_path
    ModelProviders::SetAPIKey.call(account: accounts(:cybros), provider_id: "test_api", api_key: "readiness-test-key")
    ModelProviders::EnableLane.call(account: accounts(:cybros), provider_id: "test_api", expected_lock_version: nil)
    get root_path
    assert_select "a[href=?]", admin_model_providers_path, count: 0
  end

  test "overview measures the exact rolling window and preserves unknown cost and content visibility" do
    now = Time.utc(2026, 10, 17, 12, 34, 56)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
      answering_user: users(:agent), title: "Readable work")
    hidden = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:owner),
      answering_user: users(:agent), title: "Concealed work", access_default: "none")
    receipt(conversation, at: now - 7.days, tokens: 123, cost: "1.25")
    receipt(conversation, at: now - 1.second, tokens: 4, cost: nil)
    receipt(conversation, at: now - 7.days - 1.second, tokens: 1_000, cost: "99")
    receipt(conversation, at: now, tokens: 2_000, cost: "99")
    receipt(hidden, at: now - 1.minute, tokens: 3_000, cost: "99")
    receipt(nil, at: now - 1.minute, tokens: 4_000, cost: "99")
    travel_to now do
      get root_path, params: { from: "invalid", to: "invalid", workspace_public_id: workspaces(:personal).public_id }
      assert_response :success
      assert_includes response.body, "2 calls · 127 tokens"
      assert_includes response.body, "1.25"
      assert_includes response.body, I18n.t("conversation_console.cost_incomplete")
      assert_select "a[href=?]", conversation_path(conversation, return_to: request.fullpath)
      assert_not_includes response.body, hidden.title
      assert_includes response.body, "Last 7 days"
    end
  end

  test "Agent identities count without an executor and connection guidance does not claim execution" do
    agent = create_agent_member(steward: @human, agent_identifier: "member-only")
    assert_nil Executor.address_for(agent)
    get root_path
    assert_response :success
    assert_select "a[href=?]", agents_path, text: "Agents · #{@human.stewarded_agents.count}"
    get agent_connection_path
    assert_response :success
    assert_includes response.body, "An application executor is optional"
    assert_includes response.body, "A connection alone does not verify execution"
    assert_select "a[href=?]", new_agent_path
    assert_select "main form", count: 0
  end

  test "recent work is one bounded mixed list and Agent stewardship does not bypass content access" do
    agent = create_agent_member(steward: @human, agent_identifier: "recent-work")
    now = Time.current
    visible = 6.times.map do |index|
      Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
        answering_user: agent, title: "Recent work #{index}", last_activity_at: now - index.minutes)
    end
    hidden = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:owner),
      answering_user: agent, title: "Stewardship is not content access", access_default: "none")
    standalone = Run.create!(workspace: workspaces(:shared), creating_user: agent,
      status: "running", approval_mode: "bypass")
    [root_path, agent_path(agent)].each do |path|
      get path
      assert_response :success
      assert_select "article", count: 5
      assert_select "article a[href=?]", run_path(standalone, return_to: path)
      visible.first(4).each do |conversation|
        assert_select "article a[href=?]", conversation_path(conversation, return_to: path)
      end
      assert_not_includes response.body, visible.last.title
      assert_not_includes response.body, hidden.title
    end
  end

  test "overview attention includes only actionable writable work" do
    writable = Run.create!(workspace: workspaces(:shared), creating_user: @human,
      status: "running", approval_mode: "bypass")
    hidden_conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:owner),
      answering_user: users(:agent), access_default: "none")
    hidden = create_run_backed_turn(conversation: hidden_conversation, acting_user: users(:owner)).run
    visible_task = awaiting_question(writable)
    hidden.update!(status: "running")
    hidden_task = awaiting_question(hidden)
    get root_path
    assert_response :success
    assert_select "a[href=?]", run_task_path(writable, visible_task.node_key, return_to: root_path)
    assert_select "a[href=?]", run_task_path(hidden, hidden_task.node_key, return_to: root_path), count: 0
    writable.update!(status: "canceled", stopped_at: Time.current)
    get root_path
    assert_select "a[href=?]", run_task_path(writable, visible_task.node_key, return_to: root_path), count: 0
  end

  private

    def awaiting_question(run)
      task = run.tasks.create!(type: Tasks::AwaitTask.sti_name, node_key: "question", authored_by: "model", on_failure: "halt")
      task.update!(status: "awaiting_input", started_at: Time.current, await_started_at: Time.current)
      task
    end

    def receipt(conversation, at:, tokens:, cost:)
      UsageRecord.create!(account: accounts(:cybros), idempotency_key: SecureRandom.uuid_v7,
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        consumer_user_public_id: users(:agent).public_id, conversation_public_id: conversation&.public_id,
        provider_id: "dev", catalog_model_ref: "dev/text", wire_model_id: "text",
        workload: "text_generation", purpose: "task", service_class: "interactive",
        admission_shape: "priced", status: "succeeded", recorded_at: at,
        total_tokens: tokens, cost_amount: cost)
    end
end
