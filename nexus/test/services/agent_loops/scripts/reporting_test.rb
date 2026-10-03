require "test_helper"

class AgentLoops::Scripts::ReportingTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    declare_tools!(@agent, tools: [Nexus::Compose::DEFINITION, READ_TOOL])
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "turn owned script reports only its final model result before final delivery" do
    turn, agent_loop, root, internal, mainline = start_background_script("turn")
    answer!(mainline, "Initial answer")
    assert_nil agent_loop.reload.delivered_at
    assert_equal "completed", root.reload.status
    assert_equal "running", internal.reload.status
    assert_empty AgentLoops::WakeContinuation.undelivered(agent_loop)

    answer!(internal, "FINAL SCRIPT RESULT")
    wake = loop_node(agent_loop, "w1")
    assert_equal [internal.node_key], wake.result_from_node_keys
    assert_equal [mainline.node_key], wake.input_from_node_keys
    assert_nil agent_loop.reload.delivered_at
    result_message = round_request_entries(wake).last
    assert_equal "user", result_message.fetch("role")
    assert_includes result_message.to_json, "FINAL SCRIPT RESULT"
    assert_not_includes result_message.to_json, "INTERNAL MODEL PROMPT SECRET"
    assert_not_includes result_message.to_json, "Expanded 1 task"
    answer!(wake, "Final answer with the result")
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
  end

  test "conversation owned script mails only its final model result once after delivery" do
    turn, agent_loop, root, internal, mainline = start_background_script("conversation")
    answer!(mainline, "Initial answer")
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_not_nil agent_loop.reload.delivered_at
    assert_equal "completed", root.reload.status
    assert_empty AgentLoops::Mail.call(agent_loop)

    answer!(internal, "FINAL SCRIPT RESULT")
    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    mail = @conversation.conversation_inputs.where(origin: ConversationInput::TASK_RESULT_ORIGIN).sole
    text = mail.content_bodies.find_by!(role: "input").effective_text
    assert_includes text, "FINAL SCRIPT RESULT"
    assert_not_includes text, "INTERNAL MODEL PROMPT SECRET"
    assert_not_includes text, "Expanded 1 task"
    accepted = @conversation.conversation_event_items.where(item_type: "input_accepted").order(:sequence).last.payload
    assert_equal internal.node_key, accepted.fetch("task_key")
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
  end

  test "a wait only background consumer does not acknowledge the script result" do
    agent_loop = seed(model("prefix"),
      { "script" => { "key" => "producer", "script" => 'return "READY VALUE";', "detached" => true } },
      tool("observer", "read_file", "detached" => true, "after" => ["producer"]), model("report"))
    assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?
    schedule_loop!(agent_loop)
    answer!(loop_node(agent_loop, "prefix"), "Start")
    answer!(loop_node(agent_loop, "report"), "Ready for background results")
    producer = loop_node(agent_loop, "producer")
    AgentLoops::ScriptJob.perform_now(producer.id, producer.execution_generation)
    schedule_loop!(agent_loop)

    assert_equal "dispatched", loop_node(agent_loop, "observer").status
    wake = loop_node(agent_loop, "w1")
    assert_equal [producer.node_key], wake.result_from_node_keys
    assert_includes round_request_entries(wake).to_json, "READY VALUE"
    assert_empty AgentLoops::WakeContinuation.undelivered(agent_loop.reload)
  end

  private

    def start_background_script(lifetime)
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "Do some work")
      schedule_loop!(agent_loop)
      seed = agent_loop.spine_tail
      answer!(seed, "Starting background work", tool_calls: [
        { id: "compose", name: "compose", arguments: {
          lifetime: lifetime,
          script: 'g.script({script: \'g.model({prompt: "INTERNAL MODEL PROMPT SECRET"});\'});',
        }.to_json },
      ])
      call = agent_loop.agent_loop_nodes.find_by!(tool_name: "compose")
      AgentLoops::ComposeJob.perform_now(call.id)
      schedule_loop!(agent_loop)
      root = agent_loop.agent_loop_nodes.find_by!(type: AgentLoopNodes::ScriptTask.sti_name)
      AgentLoops::ScriptJob.perform_now(root.id, root.execution_generation)
      schedule_loop!(agent_loop)
      internal = agent_loop.agent_loop_nodes.where(expansion_parent_id: root.id).sole
      assert_equal lifetime, internal.lifetime
      assert_predicate internal, :detached?
      [turn, agent_loop, root, internal, agent_loop.spine_tail]
    end

    def answer!(node, text, tool_calls: [])
      invocation = node.selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      attempt = ModelInvocationAttempt.where(model_invocation_id: invocation).order(:id).last
      apply_via(attempt, sse_success(text, tool_calls: tool_calls))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(node.agent_loop)
    end
end
