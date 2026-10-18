require "test_helper"

# Model-selected recipients are untrusted input to the Workspace owner's recipient policy.
# The run's actual answerer supplies sender identity; data-access rights remain separate.
class Runs::MessagingPolicyTest < ActiveJob::TestCase
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
    run = open_run
    execute_calls(run, ["send", { to: @room.public_id, message: "Review this" }],
      ["spawn", { agent: @peer.public_id, prompt: "Review separately" }])

    assert_equal @peer, @room.inputs.sole.answering_user
    assert_equal @peer, call_node(run, 1).spawned_conversation.answering_user
    assert_not call_node(run, 0).output_summary["is_error"]
    assert_not call_node(run, 1).output_summary["is_error"]
  end

  test "a private recipient accepts its allowlist while refusal leaves no child or input" do
    denied = create_agent_member(display_name: "Writer")
    private_for(@peer, @agent)
    private_for(denied)
    run = open_run
    execute_calls(run, ["send", { to: @room.public_id, agent: @peer.public_id, message: "Allowed" }],
      ["send", { to: @room.public_id, agent: denied.public_id, message: "Refused" }],
      ["spawn", { agent: denied.public_id, prompt: "Refused", wait: true }])

    assert_equal ["Allowed"], @room.inputs.map(&:text)
    assert_messaging_refused(call_node(run, 1))
    assert_messaging_refused(call_node(run, 2))
    assert_nil call_node(run, 2).spawned_conversation
    assert_nil run.tasks.find_by(node_key: "r2t2-spawn-1")
    assert @room.readable_by?(@agent), "messaging policy does not remove conversation access"
    assert @room.writable_by?(@agent)
  end

  test "private mode limits incoming contact without limiting outgoing contact to a public peer" do
    private_for(@agent)
    outbound = open_run
    execute_calls(outbound, ["send", { to: @room.public_id, message: "Public peer accepts" }])
    assert_equal ["Public peer accepts"], @room.inputs.map(&:text)

    inbound = open_run(answerer: @peer)
    assert_no_difference -> { @conversation.inputs.count } do
      execute_calls(inbound, ["send", { to: @conversation.public_id, message: "Private peer refuses" }])
    end
    assert_messaging_refused(call_node(inbound, 0))
  end

  test "an omitted agent on send is checked against the conversation answerer" do
    private_for(@peer)
    run = open_run
    assert_no_difference -> { @room.inputs.count } do
      execute_calls(run, ["send", { to: @room.public_id, message: "Refused" }])
    end
    assert_messaging_refused(call_node(run, 0))
  end

  test "an unnamed steer is checked against the running answerer instead of the default" do
    @room = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, running = materialize_loop_reply!(@room, agent: @agent, answering_user_public_id: @peer.public_id)
    assert_equal @peer, running.answering_user
    private_for(@peer)
    run = open_run
    execute_calls(run, ["send", { to: @room.public_id, message: "Refused steer", steer: true }],
      ["send", { to: @room.public_id, message: "Allowed queue" }])

    assert_messaging_refused(call_node(run, 0))
    assert_equal ["Allowed queue"], @room.inputs.map(&:text)
    assert_equal @agent, @room.inputs.sole.answering_user
  end

  test "self delegation remains available in private mode with an empty allowlist" do
    private_for(@agent)
    run = open_run
    execute_calls(run, ["spawn", { prompt: "Work independently" }],
      ["send", { to: @room.public_id, agent: @agent.public_id, message: "Self" }])

    assert_equal @agent, call_node(run, 0).spawned_conversation.answering_user
    assert_equal @agent, @room.inputs.sole.answering_user
    assert_not call_node(run, 1).output_summary["is_error"]
  end

  test "a named definition is the sender independently of its declaring instance and human speaker" do
    named = Users::DeclareNamedAgent.call(caller: @agent, name: "specialist", scope: "steward",
      description: "A specialist", system_prompt: "Work on the request.",
      configuration: { tool_definitions: [Nexus::Tools::SEND], approval_mode: "bypass", approval_rules: nil,
        prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil, default_model: nil }).user
    private_for(@peer, @agent)
    run = open_run(answerer: named)
    execute_calls(run, ["send", { to: @room.public_id, message: "Refused" }])

    assert_equal named, run.answering_user
    assert_messaging_refused(call_node(run, 0))
    assert_empty @room.inputs

    unrestricted = open_run
    execute_calls(unrestricted, ["send", { to: @room.public_id, message: "Instance allowed" }])
    assert_equal ["Instance allowed"], @room.inputs.map(&:text)
  end

  test "tightening contact rules does not revoke a previously accepted delayed input" do
    run = open_run
    execute_calls(run, ["send", { to: @room.public_id, message: "Accepted", deliver_in: "1h" }])
    accepted = @room.inputs.sole
    private_for(@peer)

    DatabaseClock.stub(:now, accepted.deliver_at + 1.second) do
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @room.id)
    end
    assert_equal @peer, @room.turns.sole.answering_user
    assert_equal "Accepted", @room.turns.sole.active_variant.content_bodies.find_by!(role: "prompt").effective_text
  end

  test "an accepted spawn resumes its original brief after a policy change" do
    run = open_run
    prepare_calls(run, ["spawn", { agent: @peer.public_id, prompt: "Accepted spawn", wait: true }])
    node = call_node(run, 0)
    interrupted = ->(*) { raise IOError, "input acceptance interrupted" }
    Conversations::Inputs::Create.stub(:call, interrupted) do
      assert_raises(IOError) { Runs::ConversationToolJob.perform_now(node.id) }
    end
    child = node.reload.spawned_conversation
    assert_not_nil child
    assert_empty child.inputs
    private_for(@peer)

    assert_no_difference "Conversation.count" do
      Runs::ConversationToolJob.perform_now(node.id)
    end
    assert_equal "Accepted spawn", child.inputs.sole.text
    assert_not node.reload.output_summary["is_error"]

    later = open_run
    assert_no_difference -> { child.inputs.count } do
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
      origin: Input::CHILD_ORIGIN, sender_conversation_public_id: @conversation.public_id
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
      _turn, run = materialize_loop_reply!(conversation, agent: @human, answering_user_public_id: answerer.public_id)
      schedule_loop!(run)
      run
    end

    def prepare_calls(run, *calls)
      tool_calls = calls.each_with_index.map do |(name, arguments), index|
        { id: "call_#{index}", name: name, arguments: arguments.to_json }
      end
      run_loop_round!(run, sse_success("Working", tool_calls: tool_calls))
    end

    def execute_calls(run, *calls)
      prepare_calls(run, *calls)
      calls.each_index { |index| Runs::ConversationToolJob.perform_now(call_node(run, index).id) }
    end

    def call_node(run, index) = loop_node(run, "r2t#{index}")

    def assert_messaging_refused(node)
      assert node.output_summary["is_error"]
      assert_includes node.content_bodies.find_by!(role: "output").effective_text, "messaging_not_allowed"
    end
end
