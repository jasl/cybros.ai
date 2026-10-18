require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationHistoryExecutionTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @agent = users(:agent)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "opted in history reads the accepted prompt before the first model result" do
    post inputs_path(@conversation), headers: auth("opening"), as: :json,
      params: { input: { kind: "direct_reply", text: "Investigate the unfinished task", model: { model: "dev/mock-text" } } }
    assert_response :accepted
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    turn = @conversation.turns.sole
    run = turn.active_variant.run
    assert_empty run.tasks.where(status: "completed")

    get history_path, headers: auth
    assert_response :success
    assert_not response.parsed_body.key?("execution")
    get history_path, headers: auth, params: { include_execution: true }
    assert_response :success
    body = response.parsed_body
    assert_equal "Investigate the unfinished task", body.fetch("turns").sole.fetch("prompt")
    assert_equal "running", body.fetch("turns").sole.fetch("status")
    execution = body.fetch("execution")
    assert_equal Nexus::Contract.send(:history).fetch("execution_fixture").fetch("execution").keys.sort, execution.keys.sort
    assert_equal turn.public_id, execution.fetch("turn_public_id")
    assert_equal turn.active_variant.public_id, execution.fetch("variant_public_id")
    assert_equal run.public_id, execution.fetch("run_public_id")
    assert execution.fetch("active")
    assert_equal run.status, execution.fetch("run_status")
    assert_not execution.fetch("truncated")
  end

  test "waiting continuation shows persisted calls and previews without hidden rows or UI payloads" do
    _turn, run = materialize_loop_reply!(@conversation, agent: @agent, text: "Read the files")
    schedule_loop!(run)
    run_loop_round!(run, sse_success("I am reading files", tool_calls: [
      { id: "visible", name: "read_file", arguments: "{}" },
      { id: "hidden", name: "read_file", arguments: "{}" },
    ]))
    visible = loop_node(run, "r2t0")
    visible.update!(result_title: "UI title", result_metadata: { "private_ui" => "metadata" })
    run.tasks.where(node_key: "r2t1").update_all(transcript_visibility: "hidden")

    get history_path, headers: auth, params: { include_execution: true }
    assert_response :success
    execution = response.parsed_body.fetch("execution")
    assert_includes execution.fetch("rounds").first.fetch("text_preview"), "I am reading files"
    waiting = execution.fetch("rounds").last
    assert_equal "waiting", waiting.fetch("status")
    call = waiting.fetch("calls").fetch("items").sole
    assert_equal visible.node_key, call.fetch("task_key")
    assert_equal visible.called_name, call.fetch("name")
    assert_not call.key?("output_preview")
    assert_not call.key?("title")
    assert_not call.key?("metadata")
    assert_equal 1, waiting.fetch("calls").fetch("count")
    assert_not_includes response.body, "r2t1"
  end

  test "regeneration keeps the displayed answer and selects the running candidate for execution" do
    turn, run = materialize_loop_reply!(@conversation, agent: @agent, text: "Original question")
    schedule_loop!(run)
    run_loop_round!(run, sse_success("Original answer"))
    Conversations::Turns::Converge.call
    original = turn.reload.active_variant
    post "#{turns_path(@conversation)}/#{turn.public_id}/regeneration", headers: auth("regenerate"), as: :json,
      params: { regeneration: { model: { model: "dev/mock-text" } } }
    assert_response :accepted
    candidate = response.parsed_body.fetch("variant")

    get history_path, headers: auth, params: { include_execution: true, around_turn_public_id: turn.public_id }
    assert_response :success
    body = response.parsed_body
    assert_includes body.fetch("turns").sole.fetch("content"), "Original answer"
    assert_equal original.public_id, turn.reload.active_variant.public_id
    assert_equal candidate.fetch("public_id"), body.dig("execution", "variant_public_id")
    assert_equal candidate.fetch("run_public_id"), body.dig("execution", "run_public_id")
    assert_equal false, body.dig("execution", "active")
  end

  test "retention keeps the question and answer while naming unavailable execution detail" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    seam.run.update!(completed_at: 100.days.ago)
    @conversation.reload.update!(active_turn: nil)
    ContentBodies::Replace.call(owner: seam.variant, role: "prompt", entries: [{ "text" => "question" }], seal: true)
    ContentBodies::Replace.call(owner: seam.variant, role: "content", entries: [{ "text" => "answer" }], seal: true)
    Conversations::ExecutionDetails::Prune.call(account: @account, batch: 10)

    get history_path, headers: auth, params: { include_execution: true }
    assert_response :success
    body = response.parsed_body
    assert_equal "question", body.fetch("turns").sole.fetch("prompt")
    assert_equal "answer", body.fetch("turns").sole.fetch("content")
    execution = body.fetch("execution")
    assert execution.fetch("details_pruned_at")
    assert_equal Nexus::Contract.send(:history).fetch("execution_pruned_fixture").fetch("execution").keys.sort, execution.keys.sort
    assert_equal seam.run.public_id, execution.fetch("run_public_id")
    assert_empty execution.fetch("rounds")
    assert_equal({ "next_before" => nil, "has_older" => false }, execution.fetch("pagination"))
  end

  test "execution has explicit absence and uses the transcript cursor and missing-prefix errors" do
    get history_path, headers: auth, params: { include_execution: true }
    assert_response :success
    assert response.parsed_body.key?("execution")
    assert_nil response.parsed_body.fetch("execution")
    get history_path, headers: auth, params: { include_execution: true, execution_before: "broken" }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    materialize_loop_reply!(@conversation, agent: @agent)
    get history_path, headers: auth, params: { include_execution: true, execution_prefix: "missing" }
    assert_response :not_found
  end

  test "one budget funds selected text then latest execution before neighboring history and pages rounds independently" do
    7.times { append_message(@conversation, "old context " * 300) }
    seam = create_run_backed_turn(conversation: @conversation.reload, acting_user: @human)
    ContentBodies::Replace.call(owner: seam.variant, role: "prompt",
      entries: [{ "text" => "selected question " * 200 }], seal: true)
    plant_transcript(seam.run)

    get history_path, headers: auth, params: { include_execution: true }
    assert_response :success
    body = response.parsed_body
    assert_includes body.fetch("turns").last.fetch("prompt"), "selected question"
    assert_empty body.fetch("turns").first.fetch("content")
    execution = body.fetch("execution")
    assert execution.fetch("truncated")
    assert body.fetch("truncated")
    assert_equal 20, execution.fetch("rounds").length
    assert_empty execution.fetch("rounds").first.fetch("text_preview")
    assert_equal "r25 " * 56, execution.fetch("rounds").last.fetch("text_preview")
    assert_equal 12_000, text_size(body)
    cursor = execution.fetch("pagination").fetch("next_before")
    assert execution.fetch("pagination").fetch("has_older")

    get history_path, headers: auth,
      params: { include_execution: true, execution_before: cursor, around_turn_public_id: seam.turn.public_id }
    assert_response :success
    assert_equal %w[r1 r2 r3 r4 r5], response.parsed_body.dig("execution", "rounds").map { |round| round.fetch("task_key") }
    assert_not response.parsed_body.dig("execution", "pagination", "has_older")
    assert_nil response.parsed_body.dig("execution", "pagination", "next_before")

    get history_path, headers: auth, params: { include_execution: true, execution_prefix: "r25t0" }
    assert_response :success
    branch = response.parsed_body.dig("execution", "rounds").sole
    assert_equal "r25t0-model-1", branch.fetch("task_key")
    assert_equal false, branch.fetch("mainline")
  end

  test "an inherited answer grants no access to its source Run after source concealment" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    ContentBodies::Replace.call(owner: seam.variant, role: "content", entries: [{ "text" => "inherited answer" }], seal: true)
    @conversation.reload.update!(active_turn: nil)
    boundary = append_message(@conversation, "fork boundary")
    post conversation_forks_path(@conversation), headers: auth("fork"), as: :json,
      params: { fork: { turn_public_id: boundary.public_id } }
    assert_response :created
    fork = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    other = create_access_token_fixture(user: users(:curator), name: "Inherited reader")
    headers = { "Authorization" => "Bearer #{other.secret}" }
    path = "#{conversation_path(fork)}/history"
    get path, headers: headers, params: { include_execution: true, around_turn_public_id: seam.turn.public_id }
    assert_response :success
    assert_equal seam.run.public_id, response.parsed_body.dig("execution", "run_public_id")

    @conversation.reload.update!(access_default: "none")
    get path, headers: headers, params: { include_execution: true, around_turn_public_id: seam.turn.public_id }
    assert_response :success
    assert_equal "inherited answer", response.parsed_body.fetch("turns").first.fetch("content")
    assert_nil response.parsed_body.fetch("execution")
    @conversation.update!(access_default: "full", tombstoned_at: Time.current)
    get path, headers: headers, params: { include_execution: true, around_turn_public_id: seam.turn.public_id }
    assert_response :success
    assert_nil response.parsed_body.fetch("execution")
  end

  test "attention explains a pending question although its visible ask call has completed" do
    declare_tools!(@agent, tools: [Nexus::Tools::ASK])
    _turn, run = materialize_loop_reply!(@conversation, agent: @agent, text: "Clarify the task")
    schedule_loop!(run)
    run_loop_round!(run, sse_success("I need a decision", tool_calls: [
      { id: "question", name: "ask", arguments: { prompt: "Which file?" }.to_json },
    ]))
    Runs::AskJob.perform_now(loop_node(run, "r2t0").id)
    schedule_loop!(run)

    get history_path, headers: auth, params: { include_execution: true }
    assert_response :success
    execution = response.parsed_body.fetch("execution")
    assert_equal "running", execution.fetch("run_status")
    assert_equal "awaiting_human", execution.fetch("attention_reason")
    assert_equal "completed", execution.fetch("rounds").last.fetch("calls").fetch("items").sole.fetch("status")
    assert_not_includes response.body, "r2t0-ask-1"
  end

  private

    def history_path = "#{conversation_path(@conversation)}/history"

    def append_message(conversation, text)
      post inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { text: text } }
      assert_response :accepted
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
      conversation.turns.order(:position).last
    end

    def plant_transcript(run)
      rows = (1..25).flat_map do |number|
        key = "r#{number}"
        [{ node_key: key, type: Tasks::ModelTask.sti_name, output_preview: "#{key} " * 56 }] +
          Array.new(24) do |index|
            { node_key: "#{key}t#{index}", type: Tasks::ToolTask.sti_name,
              tool_name: "read_file", output_preview: "tool result " * 23 }
          end
      end
      rows << { node_key: "r25t0-model-1", type: Tasks::ModelTask.sti_name,
        continuation_source: "branch", output_preview: "branch preview" }
      now = Time.current
      Task.insert_all!(rows.map do |row|
        { account_id: run.account_id, run_id: run.id, status: "completed", authored_by: "kernel",
          created_at: now, updated_at: now, tool_name: nil, continuation_source: nil, **row }
      end)
    end

    def text_size(body)
      body.fetch("turns").sum { |turn| %w[prompt steers content].sum { |field| turn.fetch(field, "").length } } +
        body.fetch("execution").fetch("rounds").sum do |round|
          round.fetch("text_preview", "").length + round.fetch("error", {}).fetch("detail", "").length +
            round.fetch("calls").fetch("items").sum { |call| call.fetch("output_preview", "").length }
        end
    end
end
