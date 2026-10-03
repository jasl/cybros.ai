require "test_helper"

class AgentLoops::InputAcceptanceTest < ActiveJob::TestCase
  include InvocationHarness

  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a continuation trusts its sealed prefix while accepting a new steer in its suffix" do
    agent_loop = seed(model("main", "prompt" => "read the accepted request", "tools" => [READ_TOOL]))
    start_loop(agent_loop)
    prefix = entries(node(agent_loop, "main").invocation_body("request"))
    assert_predicate node(agent_loop, "main").invocation_body("request"), :sealed?
    apply_round(node(agent_loop, "main"), sse_success("reading", tool_calls: [
      { id: "read_request", name: "read_file", arguments: '{"path":"request.txt"}' },
    ]))
    schedule(agent_loop)
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "read_request")
    assert_predicate AgentLoops::Parks::Settle.call(
      node: call, trusted: true, content: "the file contents", outcome: "completed"
    ), :applied?
    steer = loop_input!(agent_loop, acting_user: @human, text: "explain the contents")
    assert_predicate steer, :accepted?

    grammar = ModelSelection::Workloads::Input.method(:normalize_input)
    repeated_prefixes = []
    spy = lambda do |workload:, input:|
      submitted = Nexus::InputEntries.for(input)
      repeated_prefixes << submitted if submitted.any? { |entry| prefix.include?(entry) }
      grammar.call(workload: workload, input: input)
    end
    ModelSelection::Workloads::Input.stub(:normalize_input, spy) { schedule(agent_loop) }

    continuation = node(agent_loop, "r1")
    assert_equal "running", continuation.status
    request = continuation.invocation_body("request")
    assert_predicate request, :sealed?
    assert_equal prefix, entries(request).first(prefix.length)
    assert_equal "explain the contents", entries(request).last.dig("parts", 0, "text")
    assert_not ConversationInput.exists?(steer.value.id)
    apply_round(continuation, sse_success("the explanation"))
    schedule(agent_loop)
    assert_equal "completed", agent_loop.reload.status
    assert_empty repeated_prefixes, "a successfully sealed prefix must not re-enter the input grammar"
  end

  test "a newly queued picture with a blank text part refuses before consuming its input" do
    agent_loop, input = queue_picture(text: " ")
    2.times { schedule(agent_loop) }

    follow_up = node(agent_loop, "w1")
    assert_equal "failed", follow_up.status
    assert_equal "invalid_input", follow_up.error_key
    assert_nil follow_up.selected_model_invocation_id
    assert ConversationInput.exists?(input.id)
    assert_equal [picture.id], input.reload.content_body.content_uploads.pluck(:id)
    assert_empty agent_loop.conversation_event_items.where(item_type: "input_materialized")
  end

  test "a newly queued picture without a text part reaches a completed follow-up" do
    agent_loop, input = queue_picture(text: "")
    2.times { schedule(agent_loop) }

    follow_up = node(agent_loop, "w1")
    assert_equal "running", follow_up.status
    assert_not ConversationInput.exists?(input.id)
    request = follow_up.invocation_body("request")
    assert_equal [picture.public_id], request.upload_parts.map(&:public_id)
    assert_equal [picture.id], request.content_uploads.pluck(:id)
    apply_round(follow_up, sse_success("I see the diagram"))
    schedule(agent_loop)
    assert_equal "completed", agent_loop.reload.status
  end

  test "promptless authored tasks refuse at the door and a kernel task fails before minting" do
    [nil, "", " "].each do |prompt|
      assert_equal [{ "code" => "prompt_required", "path" => "steps[0].prompt" }],
        create_loop(model("empty", "prompt" => prompt)).errors
    end

    agent_loop = AgentLoop.create!(workspace: @workspace, creating_user: @human, approval_mode: "bypass")
    agent_loop.create_conversation_event_cursor!(account: @account)
    appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: agent_loop, origin: "kernel",
      steps: [AgentLoops::Tasks::Step::Model.new(key: "empty", model: MOCK_MODEL)],
      tip: AgentLoops::Tasks::Tip.seed("round")
    ))
    assert_predicate appended, :applied?
    start_loop(agent_loop)

    empty = node(agent_loop, "empty")
    assert_equal "failed", empty.status
    assert_equal "missing_input", empty.error_key
    assert_nil empty.selected_model_invocation_id
  end

  test "a raw input containing only roleless reasoning remains blocked without a request" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: @human, kind: "direct_reply", role: "user",
      entries: [{ "type" => "reasoning_item", "payload" => { "type" => "reasoning", "id" => "r1" } }],
      visible_in_context: true, delivery_mode: "queue", context_mode: "raw", context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      provider_id: "dev", model_ref: "mock-text", reasoning_effort: nil, request_options: nil
    ))
    assert_predicate accepted, :accepted?

    assert_no_difference "ModelInvocation.count" do
      assert_equal 0, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    end
    assert_equal "blocked", accepted.value.reload.state
    assert_equal "missing_input", accepted.value.blocked_reason
    assert_empty conversation.conversation_turns
  end

  test "withdrawing a planted follow-up skips it without minting an empty request" do
    agent_loop = seed(model("main", "prompt" => "answer first"))
    start_loop(agent_loop)
    queued = loop_input!(agent_loop, acting_user: @human, text: "never mind", delivery_mode: "queue")
    assert_predicate queued, :accepted?
    apply_round(node(agent_loop, "main"), sse_success("first answer"))
    schedule(agent_loop)
    follow_up = node(agent_loop, "w1")
    assert_equal "queued", follow_up.status
    removed = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: agent_loop, input_public_id: queued.value.public_id, acting_user: @human
    ))
    assert_predicate removed, :accepted?

    schedule(agent_loop)

    assert_equal "skipped", follow_up.reload.status
    assert_nil follow_up.selected_model_invocation_id
    assert_equal "completed", agent_loop.reload.status
    assert_equal node(agent_loop, "main").id, agent_loop.deliverable_node_id
  end

  private

    def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

    def entries(body) = body.content_body_entries.map { |entry| entry.content_fragment.payload }

    def start_loop(agent_loop)
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      schedule(agent_loop)
    end

    def schedule(agent_loop)
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
    end

    def apply_round(node, response)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == node.selected_model_invocation_id
      end
      assert_not_nil admitted
      apply_via(admitted.attempt, response)
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
    end

    def picture
      @picture ||= @account.content_uploads.create!(
        creating_user: @human,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(png_bytes), filename: "diagram.png", content_type: "image/png", identify: false
        )
      )
    end

    def queue_picture(text:)
      agent_loop = seed(model("main", "prompt" => "answer first"))
      start_loop(agent_loop)
      accepted = loop_input!(agent_loop, acting_user: @human, text: text,
        delivery_mode: "queue", attachments: [picture.public_id])
      assert_predicate accepted, :accepted?
      assert_equal "pending", accepted.value.state
      apply_round(node(agent_loop, "main"), sse_success("first answer"))
      [agent_loop, accepted.value]
    end
end
