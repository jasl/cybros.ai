require "test_helper"

# THE HANDOFF at the loop's address: PUT …/agent_loops/{id}/runner on a STANDALONE loop; a
# loop-backed loop's host is its conversation, so its address answers 409 `conversation_hosted`.
class AgentAPI::V1::Workspaces::AgentLoops::RunnersTest < ActionDispatch::IntegrationTest
  include LoopSeamTestHelper

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
  end

  def auth = { "Authorization" => "Bearer #{@secret}" }
  def runner_path(agent_loop) = "/agent_api/v1/workspaces/#{@workspace.public_id}/agent_loops/#{agent_loop.public_id}/runner"

  def standalone_loop
    result = AgentLoops::Create.call(AgentLoops::Create::Command.new(
      workspace: @workspace, creating_user: @human, runner_executor_public_id: @runner_a.public_id,
      steps: [{ "model" => { "key" => "seed", "model" => { "model" => "dev/mock-text" }, "prompt" => "s" } }],
      billing_subject: nil, idempotency_key: nil, approval_mode: "bypass"
    ))
    assert_predicate result, :created?, result.outcome.to_s
    result.agent_loop
  end

  test "binds a standalone loop and answers the loop document with the runner read" do
    agent_loop = standalone_loop

    put runner_path(agent_loop), headers: auth, as: :json, params: { runner: { executor_public_id: @runner_b.public_id } }

    assert_response :success
    document = response.parsed_body.fetch("agent_loop")
    assert_equal agent_loop.public_id, document.fetch("public_id")
    assert_equal @runner_b.public_id, document.dig("runner", "executor_public_id")
    assert_equal "B", document.dig("runner", "display_name")
    assert_equal @runner_b, agent_loop.reload.runner_executor

    put runner_path(agent_loop), headers: auth, as: :json, params: { runner: { executor_public_id: @runner_b.public_id } }
    assert_response :success
    assert_not response.parsed_body.key?("error")
  end

  test "the four refusals on the wire" do
    agent_loop = standalone_loop

    put runner_path(agent_loop), headers: auth, as: :json, params: { runner: { executor_public_id: SecureRandom.uuid_v7 } }
    assert_response :not_found
    assert_equal "runner_not_found", response.parsed_body.dig("error", "code")

    @runner_b.revoke
    put runner_path(agent_loop), headers: auth, as: :json, params: { runner: { executor_public_id: @runner_b.public_id } }
    assert_response :conflict
    assert_equal "runner_not_eligible", response.parsed_body.dig("error", "code")
    assert_equal "revoked", response.parsed_body.dig("error", "message")

    put runner_path(agent_loop), headers: auth, as: :json, params: { runner: {} }
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    @secret = connect_agent_session(steward: @owner, agent_identifier: "other").access_secret
    put runner_path(agent_loop), headers: auth, as: :json, params: { runner: { executor_public_id: @runner_a.public_id } }
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
  end

  test "a loop-backed loop's address answers conversation_hosted" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, runner_executor: @runner_a)
    seam = create_loop_backed_turn(conversation: conversation, acting_user: @human)

    put runner_path(seam.agent_loop), headers: auth, as: :json,
      params: { runner: { executor_public_id: @runner_b.public_id } }

    assert_response :conflict
    assert_equal "conversation_hosted", response.parsed_body.dig("error", "code")
    assert_equal @runner_a, conversation.reload.runner_executor
  end
end
