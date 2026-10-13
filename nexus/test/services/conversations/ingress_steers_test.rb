require "test_helper"

class Conversations::IngressSteersTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @actor = Speaker.register_ingress(user: @human, channel_key: "bridge:123", external_id: "456", display_name: "Ada")
  end

  test "a consumed ingress steer seals and retains the external voice rather than its controller" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    grown = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.authored(
      agent_run: seam.agent_run, steps: [model("only", "prompt" => "reply")]
    ))
    assert_predicate grown, :applied?
    accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: @human, kind: "message", role: "user",
      entries: [{ "text" => "shorter, please" }], visible_in_context: true,
      delivery_mode: "steer", context_mode: nil, context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil,
      speaker_public_id: @actor.public_id
    ))
    assert_predicate accepted, :accepted?, accepted.outcome.inspect
    assert_equal "steering", accepted.value.state
    AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    node = seam.agent_run.agent_run_tasks.find_by!(node_key: "only")
    request = ModelInvocation.find(node.selected_model_invocation_id).content_bodies.find_by!(role: "request")
    envelope = Conversations::ContextAssembly::SpeakerEnvelope.ingress(@actor, "shorter, please")
    assert_includes request.entry_payloads.flat_map { |entry| entry.fetch("parts").map { |part| part.fetch("text") } }, envelope
    assert_equal [envelope], AgentRuns::Steers::Landed.texts_by_round([node]).fetch(node.id)
    assert_not ConversationInput.exists?(accepted.value.id), "the durable tail retains attribution after consumption"
  end
end
