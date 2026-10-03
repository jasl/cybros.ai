require "test_helper"

# THE HANDOFF on the wire: PUT …/conversations/{id}/runner — a nested singular resource, a whole
# replacement of one column. 200 with the conversation document (also for the same id, idempotent by
# value), 404 `runner_not_found`, 409 `runner_not_eligible` naming why, 403 `not_authorized`, 400
# `parameter_missing` without the key.
class AgentAPI::V1::Workspaces::Conversations::RunnersTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @secret = create_access_token_fixture(user: @human, name: "Member").secret
    @runner_a = connect_runner(manager: @owner, runner_identifier: "a", display_name: "A",
      assignment_scope: :account_wide).executor_access_token.task_executor
    @runner_b = connect_runner(manager: @owner, runner_identifier: "b", display_name: "B",
      assignment_scope: :account_wide).executor_access_token.task_executor
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, runner_executor: @runner_a)
  end

  def auth = { "Authorization" => "Bearer #{@secret}" }
  def runner_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/runner"

  test "binds, answers the conversation document with the runner read, and the same id is a plain 200" do
    put runner_path, headers: auth, as: :json, params: { runner: { executor_public_id: @runner_b.public_id } }

    assert_response :success
    document = response.parsed_body.fetch("conversation")
    assert_equal @conversation.public_id, document.fetch("public_id")
    assert_equal({ "executor_public_id" => @runner_b.public_id, "display_name" => "B", "presence" => "not_yet_seen" },
      document.fetch("runner"))
    assert_equal @runner_b, @conversation.reload.runner_executor

    put runner_path, headers: auth, as: :json, params: { runner: { executor_public_id: @runner_b.public_id } }
    assert_response :success
    assert_not response.parsed_body.key?("error")
    assert_equal 1, @conversation.conversation_event_items.where(item_type: "runner_bound").count
  end

  test "runner_not_found is 404, runner_not_eligible is 409 naming the reason, a missing key is 400" do
    put runner_path, headers: auth, as: :json, params: { runner: { executor_public_id: SecureRandom.uuid_v7 } }
    assert_response :not_found
    assert_equal "runner_not_found", response.parsed_body.dig("error", "code")

    @runner_b.revoke_credentials
    put runner_path, headers: auth, as: :json, params: { runner: { executor_public_id: @runner_b.public_id } }
    assert_response :conflict
    assert_equal "runner_not_eligible", response.parsed_body.dig("error", "code")
    assert_equal "no ready credential", response.parsed_body.dig("error", "message")

    put runner_path, headers: auth, as: :json, params: { runner: {} }
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
    assert_equal @runner_a, @conversation.reload.runner_executor
  end

  test "a caller without standing is 403 not_authorized" do
    @secret = connect_agent_session(steward: @owner, agent_identifier: "other").access_secret
    agents_conversation = Conversation.create!(workspace: @workspace, creating_user: users(:agent),
      runner_executor: @runner_a)
    @conversation = agents_conversation

    put runner_path, headers: auth, as: :json, params: { runner: { executor_public_id: @runner_b.public_id } }

    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    assert_equal @runner_a, agents_conversation.reload.runner_executor
  end
end
