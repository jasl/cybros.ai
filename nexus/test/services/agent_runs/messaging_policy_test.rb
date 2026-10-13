require "test_helper"

# Model-selected recipients are untrusted input to the Workspace owner's recipient policy.
# The run's actual answerer supplies sender identity; data-access rights remain separate.
class AgentRuns::MessagingPolicyTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @peer = create_agent_member(display_name: "Reviewer")
    DevModelLane.ensure_enabled!(@account)
    [@agent, @peer].each do |agent|
      declare_tools!(agent, tools: [Nexus::Tools::SPAWN, Nexus::Tools::SEND, Nexus::Tools::STATUS])
    end
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @room = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @peer)
  end

  test "default messaging permits send and spawn to another agent" do
    agent_run = open_run
    execute_calls(agent_run, ["send", { to: @room.public_id, message: "Review this" }],
      ["spawn", { agent: @peer.public_id, prompt: "Review separately" }])

    assert_equal @peer, @room.conversation_inputs.sole.answering_user
    assert_equal @peer, call_node(agent_run, 1).spawned_conversation.answering_user
    assert_not call_node(agent_run, 0).output_summary["is_error"]
    assert_not call_node(agent_run, 1).output_summary["is_error"]
  end

  test "a private recipient accepts its allowlist while refusal leaves no child or input" do
    denied = create_agent_member(display_name: "Writer")
    private_for(@peer, @agent)
    private_for(denied)
    agent_run = open_run
    execute_calls(agent_run, ["send", { to: @room.public_id, agent: @peer.public_id, message: "Allowed" }],
      ["send", { to: @room.public_id, agent: denied.public_id, message: "Refused" }],
      ["spawn", { agent: denied.public_id, prompt: "Refused", wait: true }])

    assert_equal ["Allowed"], @room.conversation_inputs.map(&:text)
    assert_messaging_refused(call_node(agent_run, 1))
    assert_messaging_refused(call_node(agent_run, 2))
    assert_nil call_node(agent_run, 2).spawned_conversation
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "r2t2-spawn-1")
    assert @room.readable_by?(@agent), "messaging policy does not remove conversation access"
    assert @room.writable_by?(@agent)
  end

  test "private mode limits incoming contact without limiting outgoing contact to a public peer" do
    private_for(@agent)
    outbound = open_run
    execute_calls(outbound, ["send", { to: @room.public_id, message: "Public peer accepts" }])
    assert_equal ["Public peer accepts"], @room.conversation_inputs.map(&:text)

    inbound = open_run(answerer: @peer)
    assert_no_difference -> { @conversation.conversation_inputs.count } do
      execute_calls(inbound, ["send", { to: @conversation.public_id, message: "Private peer refuses" }])
    end
    assert_messaging_refused(call_node(inbound, 0))
  end

  test "an omitted agent on send is checked against the conversation answerer" do
    private_for(@peer)
    agent_run = open_run
    assert_no_difference -> { @room.conversation_inputs.count } do
      execute_calls(agent_run, ["send", { to: @room.public_id, message: "Refused" }])
    end
    assert_messaging_refused(call_node(agent_run, 0))
  end

  test "an unnamed steer is checked against the running answerer instead of the default" do
    @room = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, running = materialize_loop_reply!(@room, agent: @agent, answering_user_public_id: @peer.public_id)
    assert_equal @peer, running.answering_user
    private_for(@peer)
    agent_run = open_run
    execute_calls(agent_run, ["send", { to: @room.public_id, message: "Refused steer", steer: true }],
      ["send", { to: @room.public_id, message: "Allowed queue" }])

    assert_messaging_refused(call_node(agent_run, 0))
    assert_equal ["Allowed queue"], @room.conversation_inputs.map(&:text)
    assert_equal @agent, @room.conversation_inputs.sole.answering_user
  end

  test "self delegation remains available in private mode with an empty allowlist" do
    private_for(@agent)
    agent_run = open_run
    execute_calls(agent_run, ["spawn", { prompt: "Work independently" }],
      ["send", { to: @room.public_id, agent: @agent.public_id, message: "Self" }])

    assert_equal @agent, call_node(agent_run, 0).spawned_conversation.answering_user
    assert_equal @agent, @room.conversation_inputs.sole.answering_user
    assert_not call_node(agent_run, 1).output_summary["is_error"]
  end

  test "a named definition is the sender independently of its declaring instance and human speaker" do
    named = Users::DeclareNamedDefinition.call(caller: @agent, name: "specialist", scope: "steward",
      description: "A specialist", system_prompt: "Work on the request.",
      configuration: { tool_definitions: [Nexus::Tools::SEND], approval_mode: "bypass", approval_rules: nil,
        prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil, default_model: nil }).user
    private_for(@peer, @agent)
    agent_run = open_run(answerer: named)
    execute_calls(agent_run, ["send", { to: @room.public_id, message: "Refused" }])

    assert_equal named, agent_run.answering_user
    assert_messaging_refused(call_node(agent_run, 0))
    assert_empty @room.conversation_inputs

    unrestricted = open_run
    execute_calls(unrestricted, ["send", { to: @room.public_id, message: "Instance allowed" }])
    assert_equal ["Instance allowed"], @room.conversation_inputs.map(&:text)
  end

  test "tightening contact rules does not revoke a previously accepted delayed input" do
    agent_run = open_run
    execute_calls(agent_run, ["send", { to: @room.public_id, message: "Accepted", deliver_in: "1h" }])
    accepted = @room.conversation_inputs.sole
    private_for(@peer)

    DatabaseClock.stub(:now, accepted.deliver_at + 1.second) do
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @room.id)
    end
    assert_equal @peer, @room.conversation_turns.sole.answering_user
    assert_equal "Accepted", @room.conversation_turns.sole.active_variant.content_bodies.find_by!(role: "prompt").effective_text
  end

  test "an accepted spawn resumes its original brief after a policy change" do
    agent_run = open_run
    prepare_calls(agent_run, ["spawn", { agent: @peer.public_id, prompt: "Accepted spawn", wait: true }])
    node = call_node(agent_run, 0)
    interrupted = ->(*) { raise IOError, "input acceptance interrupted" }
    Conversations::Inputs::Create.stub(:call, interrupted) do
      assert_raises(IOError) { AgentRuns::ConversationToolJob.perform_now(node.id) }
    end
    child = node.reload.spawned_conversation
    assert_not_nil child
    assert_empty child.conversation_inputs
    private_for(@peer)

    assert_no_difference "Conversation.count" do
      AgentRuns::ConversationToolJob.perform_now(node.id)
    end
    assert_equal "Accepted spawn", child.conversation_inputs.sole.text
    assert_not node.reload.output_summary["is_error"]

    later = open_run
    assert_no_difference -> { child.conversation_inputs.count } do
      execute_calls(later, ["send", { to: child.public_id, message: "A new dispatch" }])
    end
    assert_messaging_refused(call_node(later, 0))
  end

  test "ordinary member inputs and kernel return mail keep their existing authority" do
    private_for(@peer)
    input = post_input!(@room, acting_user: @agent, text: "Member input", kind: "message")
    assert_equal @agent, input.authoring_user

    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @room, acting_user: @agent, entries: [{ "text" => "Completion" }],
      origin: ConversationInput::CHILD_ORIGIN, sender_conversation_public_id: @conversation.public_id
    ))
    assert_predicate result, :accepted?
    assert_equal "Completion", result.value.text
  end

  private

    def private_for(recipient, *senders)
      agents = @workspace.messaging_policy.agents.map(&:as_json)
        .reject { |entry| entry.fetch("agent_public_id") == recipient.public_id }
      agents << { "agent_public_id" => recipient.public_id, "mode" => "private",
        "allowed_sender_public_ids" => senders.map(&:public_id) }
      @workspace.update!(messaging_policy: { "agents" => agents })
    end

    def open_run(answerer: @agent)
      conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: answerer)
      _turn, agent_run = materialize_loop_reply!(conversation, agent: @human, answering_user_public_id: answerer.public_id)
      schedule_loop!(agent_run)
      agent_run
    end

    def prepare_calls(agent_run, *calls)
      tool_calls = calls.each_with_index.map do |(name, arguments), index|
        { id: "call_#{index}", name: name, arguments: arguments.to_json }
      end
      run_loop_round!(agent_run, sse_success("Working", tool_calls: tool_calls))
    end

    def execute_calls(agent_run, *calls)
      prepare_calls(agent_run, *calls)
      calls.each_index { |index| AgentRuns::ConversationToolJob.perform_now(call_node(agent_run, index).id) }
    end

    def call_node(agent_run, index) = loop_node(agent_run, "r2t#{index}")

    def assert_messaging_refused(node)
      assert node.output_summary["is_error"]
      assert_includes node.content_bodies.find_by!(role: "output").effective_text, "messaging_not_allowed"
    end
end
