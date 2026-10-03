require "test_helper"

class AgentLoops::PassiveMailTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::SPAWN, Nexus::Tools::SEND,
      Nexus::Compose::DEFINITION, READ_TOOL])
  end

  test "a passive task result lands once as history without starting a model and the next turn reads it" do
    _turn, agent_loop = delivered_task
    finish_round(agent_loop, "r2t0-model-1", "passive result")

    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    input = @conversation.conversation_inputs.sole
    assert_equal "message", input.kind
    assert_nil input.model_ref
    assert_nil input.tool_names
    assert_nil input.approval_mode
    assert_no_difference ["AgentLoop.count", "ModelInvocation.count"] do
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    end
    message = @conversation.conversation_turns.order(:position).last
    assert_equal %w[message user completed task_result], [message.kind, message.role, message.status, message.origin]
    assert_nil @conversation.reload.active_turn_id
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
    assert_empty @conversation.conversation_inputs.reload

    _next_turn, next_loop = open_reply("read the result")
    assert_equal 1, request_text(loop_node(next_loop, "r1")).scan(/Mock: passive result/).length
  end

  test "a passive receipt does not block an earlier queued active input" do
    _turn, agent_loop = delivered_task
    post_input!(@conversation, acting_user: @human, text: "what did it find?", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text")
    finish_round(agent_loop, "r2t0-model-1", "earlier input result")
    AgentLoops::Mail.call(agent_loop.reload)

    assert_equal 2, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turns = @conversation.conversation_turns.order(:position).last(2)
    assert_equal %w[message direct_reply], turns.map(&:kind)
    next_loop = turns.last.active_variant.agent_loop
    schedule_loop!(next_loop)
    assert_includes request_text(loop_node(next_loop, "r1")), "Mock: earlier input result"
    assert_empty @conversation.conversation_inputs.reload
  end

  test "a fast passive task remains history only after the original reply" do
    turn, agent_loop = open_reply("review in the background")
    call_round(agent_loop, "r1", "task", prompt: "review", wake: "passive")
    finish_round(agent_loop, "r2t0-model-1", "fast passive result")
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
    assert_empty @conversation.conversation_inputs.reload
    finish_round(agent_loop, "r2", "original answer")
    Conversations::Turns::Converge.call

    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "w1")
    assert_equal "Mock: original answer", turn.reload.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    assert_equal "message", @conversation.conversation_inputs.reload.sole.kind
    assert_no_difference ["AgentLoop.count", "ModelInvocation.count"] do
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    end
    assert_nil @conversation.reload.active_turn_id
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
  end

  test "a fast composed result becomes a supplementary turn instead of a wake round" do
    turn, agent_loop = open_reply("run a composed review")
    call_round(agent_loop, "r1", "compose", script: 'g.model({prompt: "Review", key: "review"});')
    finish_round(agent_loop, "r2t0-review", "fast composed result")
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
    finish_round(agent_loop, "r2", "original answer")
    Conversations::Turns::Converge.call

    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "w1")
    assert_equal "Mock: original answer", turn.reload.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    assert_equal "direct_reply", @conversation.conversation_inputs.sole.kind
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    next_loop = @conversation.reload.active_turn.active_variant.agent_loop
    schedule_loop!(next_loop)
    assert_equal 1, request_text(loop_node(next_loop, "r1")).scan(/Mock: fast composed result/).length
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
  end

  test "a compose started with wait true joins the current answer without mail" do
    turn, agent_loop = open_reply("compose a required review")
    call_round(agent_loop, "r1", "compose", wait: true, script: 'g.model({prompt: "Review", key: "review"});')
    assert_equal "queued", loop_node(agent_loop, "r2").status
    finish_round(agent_loop, "r2t0-review", "waited composed result")
    assert_includes round_request_entries(loop_node(agent_loop, "r2")).to_json, "Mock: waited composed result"
    finish_round(agent_loop, "r2", "answer using the review")
    Conversations::Turns::Converge.call

    assert_equal "completed", turn.reload.status
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
    assert_empty @conversation.conversation_inputs.reload
  end

  test "a passive receipt waits behind an active turn and later input still drains" do
    _turn, agent_loop = delivered_task
    busy_turn, busy_loop = open_reply("keep working")
    finish_round(agent_loop, "r2t0-model-1", "busy result")
    AgentLoops::Mail.call(agent_loop.reload)
    post_input!(@conversation, acting_user: @human, text: "continue", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text")

    assert_equal :conversation_busy, Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert_equal "running", busy_turn.reload.status
    finish_round(busy_loop, "r1", "done with current work")
    Conversations::Turns::Converge.call

    assert_equal 2, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    next_loop = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    schedule_loop!(next_loop)
    assert_includes request_text(loop_node(next_loop, "r1")), "Mock: busy result"
  end

  test "passive delivery does not require its original model to remain available" do
    _turn, agent_loop = delivered_task
    finish_round(agent_loop, "r2t0-model-1", "result before retirement")
    ModelProviderPolicy.where(account: @account, provider_id: "dev").update_all(enabled: false)

    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    assert_no_difference ["AgentLoop.count", "ModelInvocation.count"] do
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    end
    assert_nil @conversation.reload.active_turn_id
    assert_empty @conversation.conversation_inputs.reload
    assert_includes @conversation.conversation_turns.order(:position).last.active_variant
      .content_bodies.find_by!(role: "content").effective_text, "Mock: result before retirement"
  end

  test "passive wake does not release a turn-owned result from final synthesis" do
    turn, agent_loop = open_reply("review before finishing")
    call_round(agent_loop, "r1", "task", prompt: "needed review", lifetime: "turn", wake: "passive")
    finish_round(agent_loop, "r2", "candidate answer")
    refute_predicate agent_loop.reload, :delivered?

    finish_round(agent_loop, "r2t0-model-1", "required result")
    wake = loop_node(agent_loop, "w1")
    assert_includes request_text(wake), "Mock: required result"
    assert_equal "auto", wake.wake, "the receiver retains its own delivery policy"
    finish_round(agent_loop, "w1", "synthesized result")
    Conversations::Turns::Converge.call
    assert_predicate agent_loop.reload, :delivered?
    assert_equal "completed", turn.reload.status
    assert_empty @conversation.conversation_inputs.reload
  end

  test "compose and a later script expansion retain passive result delivery" do
    _turn, agent_loop = open_reply("run a dynamic background review")
    call_round(agent_loop, "r1", "compose", wake: "passive",
      script: 'g.script({key: "stage", script: \'g.model({prompt: "Review the result."});\'});')
    script = loop_node(agent_loop, "r2t0-stage")
    nested = agent_loop.agent_loop_nodes.find_by!(expansion_parent: script)
    assert_equal "passive", script.wake
    assert_equal "passive", nested.wake
    finish_round(agent_loop, "r2", "background started")
    Conversations::Turns::Converge.call
    finish_round(agent_loop, nested.node_key, "dynamic result")

    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    mail = @conversation.conversation_inputs.sole
    assert_equal "message", mail.kind
    assert_includes mail.text, "Mock: dynamic result"
    refute_includes mail.text, "Review the result."
  end

  # The mail stores what the renderer writes, so a composed tool's receipt names its call.
  test "a composed tool's mailed result names the call that produced it" do
    _turn, agent_loop = open_reply("read the log in the background")
    call_round(agent_loop, "r1", "compose", wake: "passive",
      script: 'g.tool({name: "read_file", input: {path: "log.txt"}, key: "log"});')
    finish_round(agent_loop, "r2", "reading it")
    Conversations::Turns::Converge.call
    settled = AgentLoops::Parks::Settle.call(node: loop_node(agent_loop, "r2t0-log"), trusted: true,
      content: "the log's lines", outcome: "completed")
    assert_predicate settled, :applied?, settled.outcome.inspect

    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    assert_equal "<task_result task=\"r2t0-log\" status=\"completed\">\n<call>read_file {\"path\":\"log.txt\"}</call>\n" \
                 "the log's lines\n</task_result>", @conversation.conversation_inputs.sole.text
  end

  test "a spawned reply and a later send choose their own passive wake policy" do
    _turn, agent_loop = open_reply("spawn a reviewer")
    call_round(agent_loop, "r1", "spawn", prompt: "review", wake: "passive")
    child = loop_node(agent_loop, "r2t0").spawned_conversation
    finish_round(agent_loop, "r2", "review pending")
    Conversations::Turns::Converge.call
    finish_child(child, "first report")
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)

    assert_equal "message", @conversation.conversation_inputs.sole.kind
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_nil @conversation.reload.active_turn_id

    _next_turn, next_loop = open_reply("request details")
    call_round(next_loop, "r1", "send", to: child.public_id, message: "more detail", wake: "auto")
    finish_round(next_loop, "r2", "details pending")
    Conversations::Turns::Converge.call
    finish_child(child, "second report")
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)

    mail = @conversation.conversation_inputs.sole
    assert_equal "direct_reply", mail.kind, "the later request overrides the original spawn policy"
    assert_includes mail.text, "Mock: second report"
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_not_nil @conversation.reload.active_turn_id
  end

  test "a fast spawned reply and a fast later send both wait for a supplementary turn" do
    turn, agent_loop = open_reply("spawn a reviewer")
    call_round(agent_loop, "r1", "spawn", prompt: "review")
    child = loop_node(agent_loop, "r2t0").spawned_conversation
    finish_child(child, "first fast report")
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_equal :conversation_busy, Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "w1")
    refute_includes request_text(loop_node(agent_loop, "r2")), "Mock: first fast report"
    finish_round(agent_loop, "r2", "original answer")
    Conversations::Turns::Converge.call
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_equal "Mock: original answer", turn.reload.active_variant.content_bodies.find_by!(role: "content").effective_text

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    reply_loop = @conversation.reload.active_turn.active_variant.agent_loop
    schedule_loop!(reply_loop)
    assert_equal 1, request_text(loop_node(reply_loop, "r1")).scan(/Mock: first fast report/).length
    call_round(reply_loop, "r1", "send", to: child.public_id, message: "more detail")
    finish_child(child, "second fast report")
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_equal :conversation_busy, Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    refute_includes request_text(loop_node(reply_loop, "r2")), "Mock: second fast report"
    finish_round(reply_loop, "r2", "details requested")
    Conversations::Turns::Converge.call
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    final_loop = @conversation.reload.active_turn.active_variant.agent_loop
    schedule_loop!(final_loop)
    assert_equal 1, request_text(loop_node(final_loop, "r1")).scan(/Mock: second fast report/).length
    assert_empty @conversation.conversation_inputs.reload
  end

  test "an explicitly waited spawned reply joins the current answer without mail" do
    turn, agent_loop = open_reply("wait for a reviewer")
    call_round(agent_loop, "r1", "spawn", prompt: "review", wait: true)
    child = loop_node(agent_loop, "r2t0").spawned_conversation
    assert_equal "queued", loop_node(agent_loop, "r2").status
    finish_child(child, "waited report")
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    schedule_loop!(agent_loop)
    assert_includes round_request_entries(loop_node(agent_loop, "r2")).to_json, "Mock: waited report"
    finish_round(agent_loop, "r2", "answer using the report")
    Conversations::Turns::Converge.call
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)

    assert_equal "completed", turn.reload.status
    assert_empty @conversation.conversation_inputs.reload
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
  end

  test "invalid model-authored wake values produce an error without starting delegated work" do
    _turn, agent_loop = open_reply("delegate")
    call_round(agent_loop, "r1", "task", prompt: "review", wake: "never")
    call = loop_node(agent_loop, "r2t0")
    assert_predicate call, :terminal?
    assert call.output_summary.fetch("is_error")
    assert_includes call.output_body.effective_text, 'wake must be "auto" or "passive"'
    refute agent_loop.agent_loop_nodes.exists?(node_key: "r2t0-model-1")
  end

  private

    def open_reply(text)
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: text)
      schedule_loop!(agent_loop)
      [turn, agent_loop]
    end

    def attempt_for(agent_loop, key)
      invocation_id = loop_node(agent_loop, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def call_round(agent_loop, key, name, **arguments)
      apply_via(attempt_for(agent_loop, key), sse_success("delegating", tool_calls: [
        { id: "call_#{name}", name: name, arguments: arguments.to_json },
      ]))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ComposeJob, AgentLoops::ScriptJob,
        AgentLoops::ConversationToolJob, AgentLoops::ScheduleJob]) do
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      end
      agent_loop.reload
    end

    def finish_round(agent_loop, key, text)
      apply_via(attempt_for(agent_loop, key), sse_success(text))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
    end

    def delivered_task
      turn, agent_loop = open_reply("run a background review")
      call_round(agent_loop, "r1", "task", prompt: "review", wake: "passive")
      finish_round(agent_loop, "r2", "review pending")
      Conversations::Turns::Converge.call
      [turn, agent_loop]
    end

    def finish_child(child, text)
      result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
      assert_predicate result, :accepted?, result.outcome.inspect
      child_loop = result.value.active_variant.agent_loop
      schedule_loop!(child_loop)
      finish_round(child_loop, "r1", text)
      Conversations::Turns::Converge.call
    end

    def request_text(node)
      round_request_entries(node).filter_map { |entry| entry.dig("parts", 0, "text") }.join("\n")
    end
end
