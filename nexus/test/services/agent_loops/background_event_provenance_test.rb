require "test_helper"

class AgentLoops::BackgroundEventProvenanceTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::ASK, READ_TOOL])
  end

  test "a standalone task names its loop without inventing a turn or variant" do
    agent_loop = seed(model("only"))
    item = agent_loop.conversation_event_items.sole

    assert_equal "task_status", item.item_type
    assert_equal({ "agent_loop_public_id" => agent_loop.public_id },
      item.payload.slice("agent_loop_public_id", "turn_public_id", "variant_public_id"))
  end

  test "a background completion after the next turn starts keeps its originating identities" do
    old_turn, old_loop = delivered_turn!
    current_turn, current_loop = open_turn!("continue with another question")
    boundary = last_sequence

    run_round!(old_loop, "r2t0-model-1", "background answer")

    assert_equal "completed", old_loop.reload.status
    assert_equal "running", current_loop.reload.status
    assert_equal current_turn.id, @conversation.reload.active_turn_id
    items = items_after(boundary)
    assert_equal %w[round_result task_status turn_status usage], items.map(&:item_type).uniq.sort
    assert_source(items, old_loop, old_turn)
  end

  test "a background question after the next turn starts belongs to the old turn" do
    old_turn, old_loop = delivered_turn!
    current_turn, current_loop = open_turn!("continue with another question")
    boundary = last_sequence

    call_round!(old_loop, "r2t0-model-1", "ask", { prompt: "Which database?" })

    assert_equal "completed", old_turn.reload.status
    assert_equal "awaiting_human", old_loop.reload.attention_reason
    assert_equal "running", current_loop.reload.status
    assert_equal current_turn.id, @conversation.reload.active_turn_id
    items = items_after(boundary)
    attention = items.select { |item| item.item_type == "attention_required" }.sole
    assert_equal "awaiting_human", attention.payload.fetch("reason")
    assert_source(items, old_loop, old_turn)
  end

  test "regeneration birth and the previous background cancellation name their own variants" do
    turn, old_loop = delivered_turn!
    old_variant = turn.active_variant
    boundary = last_sequence
    call_round!(old_loop, "r2t0-model-1", "ask", { prompt: "Which database?" })
    question_items = items_after(boundary)
    assert_equal "awaiting_human", question_items.find { |item| item.item_type == "attention_required" }.payload.fetch("reason")
    assert_source(question_items, old_loop, turn)

    boundary = last_sequence
    regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate regenerated, :accepted?
    new_variant = regenerated.value
    new_loop = new_variant.agent_loop
    assert_equal old_variant.id, turn.reload.active_variant_id, "the old answer is still displayed"
    birth = items_after(boundary).select { |item| item.item_type == "task_status" }
    assert_equal ["r1"], birth.map { |item| item.payload.fetch("task_key") }
    assert_source(birth, new_loop, turn)

    boundary = last_sequence
    settle_stopped_loop!(old_loop)
    assert_equal "canceled", old_loop.reload.status
    assert_equal "running", new_loop.reload.status
    assert_equal new_variant.id, new_loop.conversation_turn_variant_id
    items = items_after(boundary)
    assert items.any? { |item| item.item_type == "task_status" && item.payload["status"] == "canceled" }
    assert_source(items, old_loop, turn)
  end

  test "a previous variant's background cancellation keeps the regenerated turn's steer bound" do
    turn, old_loop = delivered_turn!
    regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate regenerated, :accepted?
    new_loop = regenerated.value.agent_loop
    steer = post_input!(@conversation, acting_user: @human, text: "include the failing checks",
      delivery_mode: "steer")
    assert_equal "steering", steer.state
    assert_equal turn.id, steer.steering_target_turn_id

    settle_stopped_loop!(old_loop)

    assert_equal "canceled", old_loop.reload.status
    assert_equal "running", new_loop.reload.status
    assert_equal "steering", steer.reload.state,
      "the old variant cannot release input waiting for the new variant's model boundary"
    assert_equal turn.id, steer.steering_target_turn_id
    schedule_loop!(new_loop)
    assert_includes round_request_entries(loop_node(new_loop, "r1")).to_json, "include the failing checks"
  end

  private

    def settle_stopped_loop!(agent_loop)
      schedule_loop!(agent_loop)
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
    end

    def open_turn!(text)
      post_input!(@conversation, acting_user: @human, text: text)
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
      schedule_loop!(agent_loop)
      [turn, agent_loop]
    end

    def delivered_turn!
      turn, agent_loop = open_turn!("run the suite while I keep working")
      call_round!(agent_loop, "r1", "task", { prompt: "long test run" })
      run_round!(agent_loop, "r2", "the reply is ready")
      assert_predicate agent_loop.reload, :delivered?
      assert_equal "running", loop_node(agent_loop, "r2t0-model-1").status
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      [turn, agent_loop]
    end

    def attempt_for(agent_loop, key)
      invocation_id = loop_node(agent_loop, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def call_round!(agent_loop, key, name, arguments)
      calls = [{ id: "call_#{name}", name: name, arguments: arguments.to_json }]
      apply_via(attempt_for(agent_loop, key), sse_success("delegating", tool_calls: calls))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      end
    end

    def run_round!(agent_loop, key, text)
      apply_via(attempt_for(agent_loop, key), sse_success(text))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
    end

    def last_sequence = @conversation.conversation_event_items.maximum(:sequence)

    def items_after(sequence)
      @conversation.conversation_event_items.where(sequence: (sequence + 1)..).order(:sequence).to_a
    end

    def assert_source(items, agent_loop, turn)
      assert_not_empty items
      identity = {
        "agent_loop_public_id" => agent_loop.public_id,
        "turn_public_id" => turn.public_id,
        "variant_public_id" => agent_loop.conversation_turn_variant.public_id,
      }
      items.each do |item|
        assert_equal identity, item.payload.slice(*identity.keys), "#{item.item_type} must retain its source"
      end
    end
end
