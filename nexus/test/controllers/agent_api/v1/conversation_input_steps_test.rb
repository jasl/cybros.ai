require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationInputStepsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    @agent = users(:agent)
    declared = Users::DeclareConfiguration.call(user: @agent,
      tool_definitions: [{ "type" => "function",
                           "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }],
      approval_mode: "ask", approval_rules: nil, prompt_mechanism: nil,
      prompt_template: nil, compaction_policy: nil)
    assert_equal :declared, declared.outcome
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @steps = [
      { "tool" => { "key" => "check", "name" => "read_file", "input" => { "path" => "result.txt" } } },
      { "ask" => { "key" => "hold", "prompt" => "Check the result" } },
    ]
  end

  test "steps persist in the input projection and create receipt digest" do
    input = submit_steps
    assert_equal @steps, input.fetch("steps")
    assert_equal @steps, ConversationInput.find_by!(public_id: input.fetch("public_id")).steps

    get conversation_inputs_path(@conversation), headers: auth
    assert_response :success
    assert_equal @steps, response.parsed_body.fetch("inputs").sole.fetch("steps")

    post conversation_inputs_path(@conversation), headers: auth("with-steps"), as: :json,
      params: { input: reply_input.merge(steps: @steps) }
    assert_response :accepted
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal input, response.parsed_body.fetch("input")

    post conversation_inputs_path(@conversation), headers: auth("with-steps"), as: :json,
      params: { input: reply_input.merge(steps: []) }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal 1, @conversation.conversation_inputs.count
  end

  test "pending edits replace steps while null preserves them and an empty array clears them" do
    input = submit_steps
    path = "#{conversation_inputs_path(@conversation)}/#{input.fetch("public_id")}"
    changed = [{ "ask" => { "key" => "changed", "prompt" => "Review" } }]

    patch path, headers: auth, as: :json,
      params: { input: { steps: changed, expected_lock_version: input.fetch("lock_version") } }
    assert_response :success
    assert_equal changed, response.parsed_body.dig("input", "steps")

    patch path, headers: auth, as: :json, params: { input: { steps: nil } }
    assert_response :success
    assert_equal changed, response.parsed_body.dig("input", "steps")

    patch path, headers: auth, as: :json,
      params: { input: { steps: [], expected_lock_version: input.fetch("lock_version") } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")

    patch path, headers: auth, as: :json, params: { input: { steps: [] } }
    assert_response :success
    assert_equal [], response.parsed_body.dig("input", "steps")
  end

  test "steps are confined to queued replies and bounded as a stored array" do
    [reply_input.merge(kind: "message"), reply_input.merge(delivery_mode: "steer")].each do |input|
      post conversation_inputs_path(@conversation), headers: auth(SecureRandom.uuid_v7), as: :json,
        params: { input: input.merge(steps: @steps) }
      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    end
    [false, { "ask" => {} }].each do |steps|
      post conversation_inputs_path(@conversation), headers: auth(SecureRandom.uuid_v7), as: :json,
        params: { input: reply_input.merge(steps: steps) }
      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    end
    post conversation_inputs_path(@conversation), headers: auth(SecureRandom.uuid_v7), as: :json,
      params: { input: reply_input.merge(steps: [{ ask: { prompt: "x" * Nexus::SizeBounds.fetch(:snapshot_bound) } }]) }
    assert_response :content_too_large
    assert_equal "content_too_large", response.parsed_body.dig("error", "code")
    assert_empty @conversation.conversation_inputs
  end

  test "materialization creates authored work atomically and only the write door reveals its ask token" do
    input = submit_steps
    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    assert_predicate applied, :accepted?
    run = applied.value.active_variant.agent_run
    assert_equal %w[r1 check hold], run.agent_run_tasks.order(:id).pluck(:node_key)
    assert_equal %w[kernel author author], run.agent_run_tasks.order(:id).pluck(:authored_by)
    assert_equal @human, run.creating_user
    assert_equal @agent, run.answering_user
    assert_equal "ask", run.approval_mode
    assert_equal input.fetch("public_id"), run.agent_run_append_receipts.sole.idempotency_key
    token = run.agent_run_tasks.find_by!(node_key: "hold").resolution_token
    assert_not_nil token

    get "#{conversation_inputs_path(@conversation)}/#{input.fetch("public_id")}/materialization", headers: auth
    assert_response :success
    assert_equal run.public_id, response.parsed_body.dig("materialization", "run_public_id")
    assert_not_includes response.body, token
    get conversation_events_path(@conversation), headers: auth
    assert_response :success
    assert_not_includes response.body, token

    post "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{run.public_id}/tasks",
      headers: auth(input.fetch("public_id")), as: :json, params: { steps: @steps }
    assert_response :success
    assert response.parsed_body.dig("receipt", "replayed")
    assert_equal token, response.parsed_body.dig("receipt", "resolution_tokens", "hold")
    assert_equal 3, run.agent_run_tasks.count

    @workspace.update!(state: :archiving)
    get "#{conversation_inputs_path(@conversation)}/#{input.fetch("public_id")}/materialization", headers: auth
    assert_response :success
    assert_not_includes response.body, token
    get "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{run.public_id}", headers: auth
    assert_response :success
    assert_not_includes response.body, token
    post "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{run.public_id}/tasks",
      headers: auth(input.fetch("public_id")), as: :json, params: { steps: @steps }
    assert_response :forbidden
    assert_not_includes response.body, token
    assert_equal 3, run.agent_run_tasks.count
  end

  test "standalone run inputs refuse steps on create and edit" do
    runs_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/runs"
    post runs_path, headers: auth("standalone"), as: :json,
      params: { run: { approval_mode: "bypass", steps: [{ ask: { key: "wait", prompt: "Wait" } }] } }
    assert_response :created
    path = "#{runs_path}/#{response.parsed_body.dig("run", "public_id")}/inputs"

    post path, headers: auth("standalone-steps"), as: :json,
      params: { input: { text: "Follow up", steps: @steps } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/steps.*not admitted/i, response.parsed_body.dig("error", "message"))

    post path, headers: auth("standalone-input"), as: :json, params: { input: { text: "Follow up" } }
    assert_response :accepted
    input = response.parsed_body.fetch("input")
    patch "#{path}/#{input.fetch("public_id")}", headers: auth, as: :json, params: { input: { steps: [] } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/steps.*not admitted/i, response.parsed_body.dig("error", "message"))
    assert_nil ConversationInput.find_by!(public_id: input.fetch("public_id")).steps
  end

  test "a refused append rolls back the candidate and editing the blocked input repairs it" do
    input = submit_steps([{ "ask" => { "key" => "r1", "prompt" => "Duplicate" } }])
    assert_no_difference ["AgentRun.count", "ConversationTurn.count", "ConversationTurnVariant.count", "AgentRunTask.count"] do
      assert_no_enqueued_jobs(only: AgentRuns::ScheduleJob) do
        result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
        assert_equal :input_blocked, result.outcome
      end
    end
    queued = ConversationInput.find_by!(public_id: input.fetch("public_id"))
    assert_equal ["blocked", "duplicate_task_key"], [queued.state, queued.blocked_reason]
    assert_empty @conversation.conversation_event_items.where(item_type: "input_materialized")

    patch "#{conversation_inputs_path(@conversation)}/#{queued.public_id}", headers: auth, as: :json,
      params: { input: { steps: @steps } }
    assert_response :success
    assert_equal "pending", response.parsed_body.dig("input", "state")
    assert_nil response.parsed_body.dig("input", "blocked_reason")
    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal %w[r1 check hold], @conversation.conversation_turns.sole.active_variant.agent_run.agent_run_tasks.order(:id).pluck(:node_key)
  end

  private

    def reply_input
      { kind: "direct_reply", text: "Produce a result", model: { model: "dev/mock-text" } }
    end

    def submit_steps(steps = @steps)
      post conversation_inputs_path(@conversation), headers: auth("with-steps"), as: :json,
        params: { input: reply_input.merge(steps: steps) }
      assert_response :accepted
      response.parsed_body.fetch("input")
    end
end
