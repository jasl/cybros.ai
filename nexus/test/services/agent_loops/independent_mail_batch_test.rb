require "test_helper"

class AgentLoops::IndependentMailBatchTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  NOW = Time.utc(2026, 10, 2)

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human, answering_user: @agent)
  end

  test "independent scheduled results retain exact worker identity and open one detached summary" do
    first, first_worker = completed_callback("First result")
    second, second_worker = completed_callback("Second result")
    inputs = [first, second]

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_empty @conversation.conversation_inputs.reload
    turns = @conversation.conversation_turns.order(:position).to_a
    assert_equal %w[message direct_reply], turns.map(&:kind)
    assert_equal inputs.map(&:public_id), turns.map(&:input_public_id)
    assert_equal [first.callback_source], turns.first.callback_sources
    summary = turns.last
    assert_equal inputs.map(&:callback_source), summary.callback_sources
    assert_nil summary.sender_conversation_public_id
    assert_nil summary.sender_agent_loop_public_id
    assert_nil summary.sender_task_key
    reply = summary.active_variant.agent_loop
    schedule_loop!(reply)
    request = round_request_entries(loop_node(reply, "r1")).to_json
    assert_equal 1, request.scan("Mock: First result").length
    assert_equal 1, request.scan("Mock: Second result").length

    assert_predicate AgentLoops::Stop.stop_now(first_worker), :accepted?
    assert_predicate AgentLoops::Stop.stop_now(second_worker), :accepted?
    schedule_loop!(reply)
    assert_not_predicate reply.reload, :stopped?
    assert_equal inputs.map(&:callback_source), summary.reload.callback_sources
  end

  test "a stopped non-head source ends the batch prefix before any later callback is read" do
    first, = completed_callback("First result")
    second, worker = completed_callback("Stopped result")
    third, = completed_callback("Later result")
    worker.update!(stopped_at: Time.current)

    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal [second.public_id, third.public_id], @conversation.conversation_inputs.order(:queue_position).pluck(:public_id)
    assert_equal first.sender_agent_loop_public_id, @conversation.reload.active_turn.sender_agent_loop_public_id
  end

  test "an ancestor cut after the accepted head fence cannot produce an empty materialization" do
    first, = completed_callback("First result")
    second, = completed_callback("Second result")
    reads = 0
    stopped = AgentLoops::SourceWork.method(:stopped?)
    result = AgentLoops::SourceWork.stub(:stopped?, ->(public_id, source) {
      if public_id == first.sender_agent_loop_public_id
        reads += 1
        reads > 1
      else
        stopped.call(public_id, source)
      end
    }) { Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id) }

    assert_predicate result, :accepted?
    assert_equal [first.callback_source, second.callback_source], result.value.callback_sources
    assert_empty @conversation.conversation_inputs
  end

  test "unknown requesters retain worker pointers and never merge independent sources" do
    first, second = AgentLoops::CallbackResult.stub(:requester, nil) do
      [completed_callback("First result", requester_unknown: true).first,
        completed_callback("Second result", requester_unknown: true).first]
    end
    assert_nil first.callback_result.fetch("requester_actor_public_id")
    assert_nil second.callback_result.fetch("requester_actor_public_id")

    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal [second.public_id], @conversation.conversation_inputs.pluck(:public_id)
    assert_equal [first.callback_source], @conversation.reload.active_turn.callback_sources
  end

  test "different ingress requesters using the same author never merge" do
    actors = %w[first second].map do |external_id|
      Actor.register_ingress(user: @agent, channel_key: "telegram", external_id: external_id, display_name: external_id)
    end
    first, = completed_callback("First result", creating_user: @agent, speaker_actor_public_id: actors.first.public_id)
    second, = completed_callback("Second result", creating_user: @agent, speaker_actor_public_id: actors.last.public_id)
    assert_equal actors.map(&:public_id), [first, second].map { |input| input.callback_result.fetch("requester_actor_public_id") }

    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal [second.public_id], @conversation.conversation_inputs.pluck(:public_id)
    assert_equal [first.callback_source], @conversation.reload.active_turn.callback_sources
  end

  test "different execution memory snapshots do not share a summary" do
    first, = completed_callback("First result")
    @conversation.reload.update!(memory_context: { "bindings" => [] })
    second, = completed_callback("Second result")

    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal [second.public_id], @conversation.conversation_inputs.pluck(:public_id)
    assert_equal [first.callback_source], @conversation.reload.active_turn.callback_sources
  end

  test "truncated history rolls back the entire independent batch before consuming only its head" do
    first, = completed_callback("First result")
    second, = completed_callback("Second result")
    third, = completed_callback("Third result")
    declared = Users::DeclareConfiguration.call(user: @agent, tool_definitions: @agent.tool_definitions,
      approval_mode: @agent.approval_mode, approval_rules: @agent.approval_rules,
      prompt_mechanism: "assembly", prompt_template: { "blocks" => [{ "type" => "history", "max_entries" => 1 }, { "type" => "input" }] },
      compaction_policy: @agent.compaction_policy)
    assert_equal :declared, declared.outcome

    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal [second.public_id, third.public_id], @conversation.conversation_inputs.order(:queue_position).pluck(:public_id)
    turn = @conversation.conversation_turns.sole
    assert_equal first.public_id, turn.input_public_id
    assert_equal first.sender_agent_loop_public_id, turn.sender_agent_loop_public_id
    assert_equal [first.callback_source], turn.callback_sources
    receipts = @conversation.conversation_event_items.where(item_type: "input_materialized").map(&:payload)
    assert_equal [first.public_id], receipts.map { |item| item.fetch("input_public_id") }
  end

  private

    def completed_callback(text, creating_user: @human, requester_unknown: false, **attributes)
      result = DatabaseClock.stub(:now, NOW) do
        ScheduledJobs::Create.call(conversation: @conversation, creating_user: creating_user, attributes: {
          prompt: "Review this occurrence.", provider_id: "dev", model_ref: "mock-text",
          rule: { "kind" => "once", "run_at" => (NOW + 60).iso8601 },
        }.merge(attributes))
      end
      assert_predicate result, :accepted?, result.outcome.to_s
      job = result.value
      assert_equal :dispatched, ScheduledJobs::Dispatch.call(id: job.id, cutoff: NOW + 60)
      child = job.reload.last_execution_conversation
      accepted_input_id = child.scheduled_input_public_id
      applied = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
      assert_predicate applied, :accepted?
      turn = applied.value
      worker = turn.active_variant.agent_loop
      schedule_loop!(worker)
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      attempt = ModelInvocationAttempt.where(model_invocation_id: loop_node(worker, "r1").selected_model_invocation_id).order(:id).last
      apply_via(attempt, sse_success(text))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(worker)
      Conversations::Turns::Converge.call(conversation_id: child.id)
      create = Conversations::Inputs::Create.method(:call)
      Conversations::Inputs::Create.stub(:call, ->(command) {
        outcome = create.call(command)
        assert_predicate outcome, :accepted?, outcome.errors&.full_messages.to_s
        outcome
      }) { AgentLoops::Spawn::RelayJob.perform_now(child.id) }
      input = @conversation.conversation_inputs.order(:queue_position).last
      assert_equal({
        "conversation_public_id" => child.public_id, "input_public_id" => accepted_input_id,
        "turn_public_id" => turn.public_id, "variant_public_id" => turn.reload.active_variant.public_id,
        "requester_actor_public_id" => (turn.speaker_actor.public_id unless requester_unknown),
      }, input.callback_result)
      [input, worker]
    end
end
