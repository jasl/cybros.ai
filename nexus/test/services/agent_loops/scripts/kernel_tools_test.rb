require "test_helper"

class AgentLoops::Scripts::KernelToolsTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    declare_tools!(@agent, tools: [Nexus::Compose::DEFINITION, Nexus::Tools::ASK, Nexus::Tools::SPAWN])
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "a script generated ask holds all result and wait only consumers until the person answers" do
    agent_loop, root = start_script(<<~JS)
      const asked = g.tool({name: "ask", input: {prompt: "Which value?"}});
      const read = g.script({results: [asked], script: "return {answer: results[0].output};"});
      const follow = g.script({after: [asked], script: "return 'after the answer';"});
      g.parallel([asked, read, follow]);
      g.script({results: [read], script: "return results[0].structured_content;"});
    JS
    call = children(root).find(&:tool_call?)
    read = children(root).find { |node| node.result_from_node_keys == [call.node_key] }
    follow = children(root).find { |node| node.script? && node.result_from_node_keys.blank? }
    AgentLoops::AskJob.perform_now(call.id)
    schedule_loop!(agent_loop)
    await = agent_loop.agent_loop_nodes.find_by!(node_key: AgentLoops::Asks::Run.await_key(call.node_key))

    assert_equal "awaiting_input", await.status
    assert_equal "queued", read.reload.status
    assert_equal "queued", follow.reload.status
    assert_equal [await.node_key], read.result_from_node_keys
    assert_nil follow.result_from_node_keys

    settled = AgentLoops::Parks::Settle.call(node: await, trusted: true, outcome: "completed", content: "CHOSEN VALUE")
    assert_predicate settled, :applied?
    schedule_loop!(agent_loop)
    run_script(read.reload)
    run_script(follow.reload)
    final = children(root).find { |node| node.script? && ![read.id, follow.id].include?(node.id) }
    run_script(final.reload)

    result = round_request_entries(agent_loop.reload.spine_tail).last.to_json
    assert_includes result, "CHOSEN VALUE"
    assert_not_includes result, "Asked. The answer is in your next message"
  end

  test "a script generated waited spawn feeds its first reply into the selected result" do
    agent_loop, root = start_script(spawn_source(wait: true))
    call = children(root).find(&:tool_call?)
    reducer = children(root).find(&:script?)
    AgentLoops::ConversationToolJob.perform_now(call.id)
    schedule_loop!(agent_loop)
    await = call.reload.spawn_await

    assert_equal "dispatched", await.status
    assert_equal "queued", reducer.reload.status
    assert_equal [await.node_key], reducer.result_from_node_keys

    child = call.spawned_conversation
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_turn = child.conversation_turns.order(:position).last
    child_loop = child_turn.active_variant.agent_loop
    schedule_loop!(child_loop)
    run_loop_round!(child_loop, sse_success("CHILD FINAL VALUE"))
    Conversations::Turns::Converge.call
    AgentLoops::Spawn::RelayJob.perform_now(child.id)
    schedule_loop!(agent_loop)
    run_script(reducer.reload)

    assert_equal "completed", await.reload.status
    result = round_request_entries(agent_loop.reload.spine_tail).last.to_json
    assert_includes result, "CHILD FINAL VALUE"
    assert_not_includes result, "waiting for its first reply"
    assert_not ConversationInput.where(host: @conversation).exists?
  end

  test "a script generated nonwaiting spawn retains its immediate acknowledgement" do
    agent_loop, root = start_script(spawn_source(wait: false))
    call = children(root).find(&:tool_call?)
    reducer = children(root).find(&:script?)
    AgentLoops::ConversationToolJob.perform_now(call.id)
    schedule_loop!(agent_loop)

    assert_nil call.reload.spawn_await
    assert_equal "running", reducer.reload.status
    assert_equal [call.node_key], reducer.result_from_node_keys
    run_script(reducer)
    assert_includes reducer.reload.output_body.effective_text, "in the background"
  end

  private

    def start_script(source)
      _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "Run this workflow")
      schedule_loop!(agent_loop)
      run_loop_round!(agent_loop, sse_success("Starting", tool_calls: [
        { id: "compose", name: "compose", arguments: {
          wait: true, script: "g.script({script: params.stage});", params: { stage: source },
        }.to_json },
      ]))
      call = agent_loop.agent_loop_nodes.find_by!(tool_name: "compose")
      AgentLoops::ComposeJob.perform_now(call.id)
      schedule_loop!(agent_loop)
      root = children(call).sole
      run_script(root)
      [agent_loop, root]
    end

    def run_script(node)
      assert_equal "running", node.status
      AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
      schedule_loop!(node.agent_loop)
    end

    def children(node)
      node.agent_loop.agent_loop_nodes.where(expansion_parent_id: node.id).order(:id).to_a
    end

    def spawn_source(wait:)
      <<~JS
        const child = g.tool({name: "spawn", input: {prompt: "Return the final value", wait: #{wait}}});
        g.script({results: [child], script: "return {answer: results[0].output};"});
      JS
    end
end
