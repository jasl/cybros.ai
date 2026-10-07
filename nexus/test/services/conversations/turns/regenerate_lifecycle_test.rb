require "test_helper"

class Conversations::Turns::RegenerateLifecycleTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent, approval_mode: "ask")
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  [AgentRuns::Tasks::Approve, AgentRuns::Tasks::Deny].each do |verb|
    test "#{verb.name.demodulize} can decide a regenerating candidate while the completed answer still renders" do
      turn, original, candidate = regenerate_answer
      agent_run = candidate.agent_run
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("reading again", tool_calls: [
        { id: "read_again", name: "read_file", arguments: "{}" },
      ]))
      call = agent_run.agent_run_tasks.find_by!(tool_call_id: "read_again")
      assert_equal "needs_approval", call.status
      assert_equal original.id, turn.reload.active_variant_id
      assert_equal "running", turn.status

      result = verb.call(verb::Command.new(agent_run: agent_run.reload,
        task_key: call.node_key, acting_user: @human))

      assert_predicate result, :accepted?, result.outcome.to_s
      assert_equal "human", call.reload.approval_origin
      assert_equal @human.id, call.approved_by_user_id
      assert_equal original.id, turn.reload.active_variant_id, "a decision does not replace the displayed answer"
      assert_equal "completed", original.reload.status
    end
  end

  test "canceling a regenerating loop preserves the completed answer and its turn status" do
    turn, original, candidate = regenerate_answer
    canceled = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation.reload, acting_user: @human
    ))
    assert_predicate canceled, :accepted?
    schedule_loop!(candidate.agent_run)
    published = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { published << [stream.to_s, payload] }) do
      Conversations::Turns::Converge.call
    end

    assert_equal "canceled", candidate.agent_run.reload.status
    assert_equal "canceled", candidate.reload.status
    assert_equal "completed", turn.reload.status
    assert_equal original.id, turn.active_variant_id
    assert_includes original.content_bodies.find_by!(role: "content").effective_text, "original answer"
    assert_nil @conversation.reload.active_turn_id
    event = @conversation.conversation_event_items.where(item_type: "turn_status")
      .order(:sequence).last.payload
    assert_equal ["completed", "canceled", candidate.public_id],
      event.values_at("status", "variant_status", "variant_public_id")
    settled = published.filter_map do |stream, payload|
      item = payload.fetch(:event) if stream.end_with?(":transcript")
      item if item&.fetch(:type) == "turn"
    end.sole
    assert_equal candidate.agent_run.public_id, settled[:run_public_id],
      "the frame belongs to the candidate that settled, not the answer still displayed"
    assert_equal candidate.public_id, settled[:variant_public_id]
    assert_equal original.public_id, settled.dig(:turn, :active_variant, :public_id)
    assert_equal original.agent_run.public_id, settled.dig(:turn, :active_variant, :run_public_id)
    assert_includes settled.dig(:turn, :active_variant, :content), "original answer"
  end

  test "a terminal authority failure during regeneration preserves the completed answer" do
    turn, original, candidate = regenerate_answer
    assert_equal :suspended, @human.suspend

    schedule_loop!(candidate.agent_run)
    Conversations::Turns::Converge.call

    assert_equal ["canceled", "authority_lost"],
      candidate.agent_run.reload.values_at(:status, :failure_reason)
    assert_equal "failed", candidate.reload.status
    assert_equal "completed", turn.reload.status
    assert_equal original.id, turn.active_variant_id
    assert_nil @conversation.reload.active_turn_id
    event = @conversation.conversation_event_items.where(item_type: "turn_status")
      .order(:sequence).last.payload
    assert_equal ["completed", "failed", "authority_lost"],
      event.values_at("status", "variant_status", "failure_reason_key")
  end

  test "a repairable regeneration failure activates its held candidate and retry reopens the same turn" do
    turn, original, candidate = regenerate_answer
    agent_run = candidate.agent_run
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, json_response(400, { error: { message: "no" } }))
    Conversations::Turns::Converge.call

    assert_equal "needs_attention", agent_run.reload.status
    assert_equal "failed", turn.reload.status
    assert_equal candidate.id, turn.active_variant_id
    assert_equal "completed", original.reload.status
    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "r1", acting_user: @human
    ))
    assert_predicate retried, :accepted?, retried.outcome.to_s
    Conversations::Turns::Converge.call
    assert_equal "running", turn.reload.status
    assert_equal candidate.id, turn.active_variant_id
  end

  test "stopping an edited loop preserves a running inference candidate's steer" do
    turn, old_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "the question")
    schedule_loop!(old_loop)
    run_loop_round!(old_loop, json_response(400, { error: { message: "no" } }))
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", old_loop.reload.status
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => "my own answer" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?
    regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate regenerated, :accepted?
    assert_equal "inference", regenerated.value.source
    steer = post_input!(@conversation, acting_user: @human, text: "correct the answer", delivery_mode: "steer")
    assert_equal "steering", steer.state

    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: old_loop, acting_user: @human))
    assert_predicate stopped, :accepted?
    schedule_loop!(old_loop)

    assert_equal "canceled", old_loop.reload.status
    assert_equal "running", regenerated.value.reload.status
    assert_equal "steering", steer.reload.state
    assert_equal turn.id, steer.steering_target_turn_id
  end

  test "stopping an edited held loop releases its steer when no new candidate is running" do
    turn, old_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "the question")
    schedule_loop!(old_loop)
    steer = post_input!(@conversation, acting_user: @human, text: "correct the answer", delivery_mode: "steer")
    run_loop_round!(old_loop, json_response(400, { error: { message: "no" } }))
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", old_loop.reload.status
    assert_equal "steering", steer.reload.state
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => "my own answer" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?

    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: old_loop, acting_user: @human))
    assert_predicate stopped, :accepted?
    schedule_loop!(old_loop)

    assert_equal "canceled", old_loop.reload.status
    assert_equal "pending", steer.reload.state
    assert_nil steer.steering_target_turn_id
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal "correct the answer", @conversation.conversation_turns.order(:position).last
      .active_variant.content_bodies.find_by!(role: "content").effective_text
  end

  test "retention keeps landed steers on a failed candidate replaced by an edit before its loop stops" do
    turn, old_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "the question")
    original = turn.active_variant
    steer = post_input!(@conversation, acting_user: @human, text: "keep this correction", delivery_mode: "steer")
    schedule_loop!(old_loop)
    assert_not ConversationInput.exists?(steer.id), "the model boundary consumed the correction"
    assert loop_node(old_loop, "r1").content_bodies.exists?(role: "steers")
    run_loop_round!(old_loop, json_response(400, { error: { message: "no" } }))
    Conversations::Turns::Converge.call
    assert_equal "failed", original.reload.status
    assert_equal "needs_attention", old_loop.reload.status

    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => "my own answer" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?
    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: old_loop, acting_user: @human))
    assert_predicate stopped, :accepted?
    schedule_loop!(old_loop)
    Conversations::Turns::Converge.call
    assert_equal "canceled", old_loop.reload.status
    assert_equal "failed", original.reload.status
    assert_not original.content_bodies.exists?(role: "steers"), "the replaced candidate did not settle again"

    @account.update!(execution_details_retention_days: 1)
    travel 2.days do
      result = Conversations::ExecutionDetails::Prune.call(account: @account, batch: 10)
      assert_equal 1, result[:pruned]
    end

    assert old_loop.reload.details_pruned_at
    assert_empty old_loop.agent_run_tasks.reload
    assert_equal ["keep this correction"], Conversations::RetainedSteers.messages(original.id)
      .map { |message| message.parts.map(&:text).join }
    assert_equal "the question", original.content_bodies.find_by!(role: "prompt").effective_text
    assert_equal edited.value.id, turn.reload.active_variant_id
    assert_equal "my own answer", turn.active_variant.content_bodies.find_by!(role: "content").effective_text
  end

  private

    def regenerate_answer
      turn, origin_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "the question")
      schedule_loop!(origin_loop)
      run_loop_round!(origin_loop, sse_success("original answer"))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      original = turn.active_variant
      result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation.reload, turn_public_id: turn.public_id,
        acting_user: @human, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?, result.outcome.to_s
      [turn, original, result.value]
    end
end
