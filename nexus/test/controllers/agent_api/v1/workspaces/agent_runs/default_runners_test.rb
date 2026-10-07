require "test_helper"

# THE HANDOFF at the loop's address: PUT …/runs/{id}/runner on a STANDALONE loop; a
# loop-backed loop's host is its conversation, so its address answers 409 `conversation_hosted`.
class AgentAPI::V1::Workspaces::AgentRuns::DefaultRunnersTest < ActionDispatch::IntegrationTest
  include RunSeamTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @secret = create_access_token_fixture(user: @human, name: "Member").secret
    @runner_a = connect_runner(manager: @owner, registration_identifier: "a", display_name: "A",
      assignment_scope: :account_wide).executor_access_token.task_executor
    @runner_b = connect_runner(manager: @owner, registration_identifier: "b", display_name: "B",
      assignment_scope: :account_wide).executor_access_token.task_executor
  end

  def auth = { "Authorization" => "Bearer #{@secret}" }
  def runner_path(agent_run) = "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{agent_run.public_id}/default_runner"

  def standalone_loop
    result = AgentRuns::Create.call(AgentRuns::Create::Command.new(
      workspace: @workspace, creating_user: @human, default_runner_executor_public_id: @runner_a.public_id,
      steps: [{ "model" => { "key" => "seed", "model" => { "model" => "dev/mock-text" }, "prompt" => "s" } }],
      billing_subject: nil, idempotency_key: nil, approval_mode: "bypass"
    ))
    assert_predicate result, :created?, result.outcome.to_s
    result.agent_run
  end

  test "binds a standalone loop and answers the loop document with the runner read" do
    agent_run = standalone_loop

    put runner_path(agent_run), headers: auth, as: :json, params: { default_runner: { executor_public_id: @runner_b.public_id } }

    assert_response :success
    document = response.parsed_body.fetch("run")
    assert_equal agent_run.public_id, document.fetch("public_id")
    assert_equal @runner_b.public_id, document.dig("default_runner", "executor_public_id")
    assert_equal "B", document.dig("default_runner", "display_name")
    assert_equal @runner_b, agent_run.reload.default_runner_executor

    put runner_path(agent_run), headers: auth, as: :json, params: { default_runner: { executor_public_id: @runner_b.public_id } }
    assert_response :success
    assert_not response.parsed_body.key?("error")
  end

  test "the four refusals on the wire" do
    agent_run = standalone_loop

    put runner_path(agent_run), headers: auth, as: :json, params: { default_runner: { executor_public_id: SecureRandom.uuid_v7 } }
    assert_response :not_found
    assert_equal "runner_not_found", response.parsed_body.dig("error", "code")

    @runner_b.revoke
    put runner_path(agent_run), headers: auth, as: :json, params: { default_runner: { executor_public_id: @runner_b.public_id } }
    assert_response :conflict
    assert_equal "runner_not_eligible", response.parsed_body.dig("error", "code")
    assert_equal "revoked", response.parsed_body.dig("error", "message")

    put runner_path(agent_run), headers: auth, as: :json, params: { default_runner: {} }
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    @secret = connect_agent_session(steward: @owner, agent_identifier: "other").access_secret
    put runner_path(agent_run), headers: auth, as: :json, params: { default_runner: { executor_public_id: @runner_a.public_id } }
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
  end

  test "a loop-backed loop's address answers conversation_hosted" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: @runner_a)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)

    put runner_path(seam.agent_run), headers: auth, as: :json,
      params: { default_runner: { executor_public_id: @runner_b.public_id } }

    assert_response :conflict
    assert_equal "conversation_hosted", response.parsed_body.dig("error", "code")
    assert_equal @runner_a, conversation.reload.default_runner_executor
  end
end
