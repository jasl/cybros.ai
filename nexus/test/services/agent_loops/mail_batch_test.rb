require "test_helper"
require "test_helpers/agent_loops_mail_test_helper"

class AgentLoops::MailBatchTest < ActiveJob::TestCase
  include AgentLoopsMailTestHelper

  def queue_callback!(source, task:, text:, **surface)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: source.creating_user, kind: "direct_reply",
      entries: [{ "text" => text }], origin: ConversationInput::TASK_RESULT_ORIGIN,
      sender_conversation_public_id: @conversation.public_id, agent_loop_public_id: source.public_id,
      task_key: task, answering_user_public_id: source.answering_user.public_id,
      **AgentLoops::Mail.surface(source).merge(surface)
    ))
    assert_predicate result, :accepted?
    result.value
  end

  test "already arrived compatible callbacks keep individual receipts and open one reply" do
    _turn, source = delivered_turn!
    converge!
    first = queue_callback!(source, task: "first", text: "first completed result")
    second = queue_callback!(source, task: "second", text: "second completed result")

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_empty @conversation.conversation_inputs.reload
    turns = @conversation.conversation_turns.order(:position).last(2)
    assert_equal %w[message direct_reply], turns.map(&:kind)
    assert_equal %w[first second], turns.map(&:sender_task_key)
    assert_equal [source.public_id], turns.map(&:sender_agent_loop_public_id).uniq
    assert_equal "first completed result", turns.first.active_variant.content_bodies.find_by!(role: "content").effective_text
    reply = turns.last.active_variant.agent_loop
    schedule_loop!(reply)
    texts = round_request_entries(loop_node(reply, "r1")).to_json
    assert_equal 1, texts.scan("first completed result").length
    assert_equal 1, texts.scan("second completed result").length
    receipts = @conversation.conversation_event_items.where(item_type: "input_materialized").map(&:payload)
    assert_equal 1, receipts.count { |item| item["input_public_id"] == first.public_id }
    assert_equal 1, receipts.count { |item| item["input_public_id"] == second.public_id }

    assert_predicate AgentLoops::Stop.stop_now(source), :accepted?
    schedule_loop!(reply)
    assert_predicate reply.reload, :stopped?, "one source still owns and fences the whole supplementary reply"
  end

  test "callback batching stops at a different execution policy without skipping it" do
    _turn, source = delivered_turn!
    converge!
    first = queue_callback!(source, task: "first", text: "first result")
    second = queue_callback!(source, task: "second", text: "restricted result", tool_names: [])
    third = queue_callback!(source, task: "third", text: "third result")

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal [second.public_id, third.public_id], @conversation.conversation_inputs.order(:queue_position).pluck(:public_id)
    assert_equal "first", @conversation.reload.active_turn.sender_task_key
    assert_nil ConversationInput.find_by(public_id: first.public_id)
    texts = reply_texts.join
    assert_includes texts, "first result"
    assert_not_includes texts, "restricted result"
    assert_not_includes texts, "third result"
  end

  test "callback batching has a bounded prefix and never waits for more arrivals" do
    _turn, source = delivered_turn!
    converge!
    limit = Conversations::Inputs::CallbackBatch::CALLBACK_BATCH_LIMIT
    inputs = (limit + 1).times.map do |index|
      queue_callback!(source, task: "result-#{index}", text: "Completed result #{index}")
    end

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal [inputs.last.public_id], @conversation.conversation_inputs.pluck(:public_id)
    assert_equal "result-#{limit - 1}", @conversation.reload.active_turn.sender_task_key
  end

  test "callbacks owned by independent executions do not merge or skip ahead" do
    _first_turn, first_source = delivered_turn!
    converge!
    _second_turn, second_source = delivered_turn!
    converge!
    queue_callback!(first_source, task: "first", text: "first owner's result")
    second = queue_callback!(second_source, task: "second", text: "second owner's result")
    third = queue_callback!(first_source, task: "third", text: "first owner's later result")

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal [second.public_id, third.public_id], @conversation.conversation_inputs.order(:queue_position).pluck(:public_id)
    assert_equal first_source.public_id, @conversation.reload.active_turn.sender_agent_loop_public_id
    assert_equal "first", @conversation.active_turn.sender_task_key
  end

  test "a history entry limit keeps every callback pending until its own reply reads it" do
    _turn, source = delivered_turn!
    converge!
    declare_callback_prompt!(history: { "max_entries" => 1 })
    words = %w[first second third].map { |name| "#{name} bounded callback result" }
    inputs = words.each_with_index.map do |text, index|
      queue_callback!(source, task: "result-#{index}", text: text)
    end

    inputs.each_with_index do |input, index|
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      assert_equal inputs.drop(index + 1).map(&:public_id), pending_callback_ids
      turn = @conversation.reload.active_turn
      assert_equal "direct_reply", turn.kind
      assert_equal input.sender_task_key, turn.sender_task_key
      assert_equal source.public_id, turn.sender_agent_loop_public_id
      reply = turn.active_variant.agent_loop
      schedule_loop!(reply)
      sent = round_request_entries(loop_node(reply, "r1")).to_json
      assert_equal 1, sent.scan(words.fetch(index)).length
      words.drop(index + 1).each { |text| assert_not_includes sent, text }
      run_round!(reply, "r1", "Callback #{index} acknowledged")
      converge!
    end

    turns = @conversation.conversation_turns.where(sender_agent_loop_public_id: source.public_id).order(:position)
    assert_equal %w[direct_reply direct_reply direct_reply], turns.pluck(:kind)
    assert_equal inputs.map(&:sender_task_key), turns.pluck(:sender_task_key)
    receipts = @conversation.conversation_event_items.where(item_type: "input_materialized").map(&:payload)
    inputs.each do |input|
      assert_equal 1, receipts.count { |item| item["input_public_id"] == input.public_id }
    end
  end

  test "a stated history budget that rounds to zero cannot consume an unread callback" do
    _turn, source = delivered_turn!
    converge!
    declare_callback_prompt!(history: { "budget" => { "share" => 0.000001 } })

    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      first = queue_callback!(source, task: "first", text: "first token bounded callback", model_ref: "mock-windowed")
      second = queue_callback!(source, task: "second", text: "second token bounded callback", model_ref: "mock-windowed")

      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      assert_equal [second.public_id], pending_callback_ids
      turn = @conversation.reload.active_turn
      assert_equal "direct_reply", turn.kind
      assert_equal first.sender_task_key, turn.sender_task_key
      sent = reply_texts.join
      assert_includes sent, "first token bounded callback"
      assert_not_includes sent, "second token bounded callback"
    end
  end

  test "a raw answering profile keeps each callback in its own required input" do
    _turn, source = delivered_turn!
    converge!
    declare_callback_prompt!(mechanism: "raw")
    first = queue_callback!(source, task: "first", text: "first raw callback")
    second = queue_callback!(source, task: "second", text: "second raw callback")

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal [second.public_id], pending_callback_ids
    turn = @conversation.reload.active_turn
    assert_equal "direct_reply", turn.kind
    assert_equal first.sender_task_key, turn.sender_task_key
    assert_equal "raw", turn.active_variant.agent_loop.prompt_mechanism
    sent = reply_texts.join
    assert_includes sent, "first raw callback"
    assert_not_includes sent, "second raw callback"
  end

  private

    def pending_callback_ids
      @conversation.conversation_inputs.order(:queue_position).pluck(:public_id)
    end

    def declare_callback_prompt!(history: {}, mechanism: "assembly")
      template = { "blocks" => [{ "type" => "history" }.merge(history), { "type" => "input" }] } if mechanism == "assembly"
      declared = Users::DeclareConfiguration.call(user: @agent, tool_definitions: @agent.tool_definitions,
        approval_mode: @agent.approval_mode, approval_rules: @agent.approval_rules,
        prompt_mechanism: mechanism, prompt_template: template, compaction_policy: @agent.compaction_policy)
      assert_equal :declared, declared.outcome
    end
end
