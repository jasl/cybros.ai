require "test_helper"

class AgentRuns::InputAcceptanceTest < ActiveJob::TestCase
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
    agent_run = seed(model("main", "prompt" => "read the accepted request", "tools" => [READ_TOOL]))
    start_loop(agent_run)
    prefix = entries(node(agent_run, "main").invocation_body("request"))
    assert_predicate node(agent_run, "main").invocation_body("request"), :sealed?
    apply_round(node(agent_run, "main"), sse_success("reading", tool_calls: [
      { id: "read_request", name: "read_file", arguments: '{"path":"request.txt"}' },
    ]))
    schedule(agent_run)
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "read_request")
    assert_predicate AgentRuns::Parks::Settle.call(
      node: call, trusted: true, content: "the file contents", outcome: "completed"
    ), :applied?
    steer = loop_input!(agent_run, acting_user: @human, text: "explain the contents")
    assert_predicate steer, :accepted?

    grammar = ModelSelection::Workloads::Input.method(:normalize_input)
    repeated_prefixes = []
    spy = lambda do |workload:, input:|
      submitted = Nexus::InputEntries.for(input)
      repeated_prefixes << submitted if submitted.any? { |entry| prefix.include?(entry) }
      grammar.call(workload: workload, input: input)
    end
    ModelSelection::Workloads::Input.stub(:normalize_input, spy) { schedule(agent_run) }

    continuation = node(agent_run, "r1")
    assert_equal "running", continuation.status
    request = continuation.invocation_body("request")
    assert_predicate request, :sealed?
    assert_equal prefix, entries(request).first(prefix.length)
    assert_equal "explain the contents", entries(request).last.dig("parts", 0, "text")
    assert_not ConversationInput.exists?(steer.value.id)
    apply_round(continuation, sse_success("the explanation"))
    schedule(agent_run)
    assert_equal "completed", agent_run.reload.status
    assert_empty repeated_prefixes, "a successfully sealed prefix must not re-enter the input grammar"
  end

  test "a newly queued picture with a blank text part refuses before consuming its input" do
    agent_run, input = queue_picture(text: " ")
    2.times { schedule(agent_run) }

    follow_up = node(agent_run, "w1")
    assert_equal "failed", follow_up.status
    assert_equal "invalid_input", follow_up.error_key
    assert_nil follow_up.selected_model_invocation_id
    assert ConversationInput.exists?(input.id)
    assert_equal [picture.id], input.reload.content_body.content_uploads.pluck(:id)
    assert_empty agent_run.conversation_event_items.where(item_type: "input_materialized")
  end

  test "a newly queued picture without a text part reaches a completed follow-up" do
    agent_run, input = queue_picture(text: "")
    2.times { schedule(agent_run) }

    follow_up = node(agent_run, "w1")
    assert_equal "running", follow_up.status
    assert_not ConversationInput.exists?(input.id)
    request = follow_up.invocation_body("request")
    assert_equal [picture.public_id], request.upload_parts.map(&:public_id)
    assert_equal [picture.id], request.content_uploads.pluck(:id)
    apply_round(follow_up, sse_success("I see the diagram"))
    schedule(agent_run)
    assert_equal "completed", agent_run.reload.status
  end

  test "promptless authored tasks refuse at the door and a kernel task fails before minting" do
    [nil, "", " "].each do |prompt|
      assert_equal [{ "code" => "prompt_required", "path" => "steps[0].prompt" }],
        create_loop(model("empty", "prompt" => prompt)).errors
    end

    agent_run = AgentRun.create!(workspace: @workspace, creating_user: @human, approval_mode: "bypass")
    agent_run.create_conversation_event_cursor!(account: @account)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "kernel",
      steps: [AgentRuns::Tasks::Step::Model.new(key: "empty", model: MOCK_MODEL)],
      tip: AgentRuns::Tasks::Tip.seed("round")
    ))
    assert_predicate appended, :applied?
    start_loop(agent_run)

    empty = node(agent_run, "empty")
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
    agent_run = seed(model("main", "prompt" => "answer first"))
    start_loop(agent_run)
    queued = loop_input!(agent_run, acting_user: @human, text: "never mind", delivery_mode: "queue")
    assert_predicate queued, :accepted?
    apply_round(node(agent_run, "main"), sse_success("first answer"))
    schedule(agent_run)
    follow_up = node(agent_run, "w1")
    assert_equal "queued", follow_up.status
    removed = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: agent_run, input_public_id: queued.value.public_id, acting_user: @human
    ))
    assert_predicate removed, :accepted?

    schedule(agent_run)

    assert_equal "skipped", follow_up.reload.status
    assert_nil follow_up.selected_model_invocation_id
    assert_equal "completed", agent_run.reload.status
    assert_equal node(agent_run, "main").id, agent_run.deliverable_node_id
  end

  private

    def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

    def entries(body) = body.content_body_entries.map { |entry| entry.content_fragment.payload }

    def start_loop(agent_run)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
      schedule(agent_run)
    end

    def schedule(agent_run)
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end

    def apply_round(node, response)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == node.selected_model_invocation_id
      end
      assert_not_nil admitted
      apply_via(admitted.attempt, response)
      AgentRuns::ConvergeTerminalSteps.call
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
      agent_run = seed(model("main", "prompt" => "answer first"))
      start_loop(agent_run)
      accepted = loop_input!(agent_run, acting_user: @human, text: text,
        delivery_mode: "queue", attachments: [picture.public_id])
      assert_predicate accepted, :accepted?
      assert_equal "pending", accepted.value.state
      apply_round(node(agent_run, "main"), sse_success("first answer"))
      [agent_run, accepted.value]
    end
end
