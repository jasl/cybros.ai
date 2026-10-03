require "test_helper"

class AgentLoops::QueuedAttachmentTest < ActiveJob::TestCase
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
    @picture = @account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(png_bytes), filename: "diagram.png", content_type: "image/png", identify: false
      )
    )
  end

  test "an image-only queued input starts one follow-up round instead of repeatedly planting skipped rounds" do
    agent_loop, input = queue_picture(text: "")
    3.times { schedule(agent_loop) }

    assert_not ConversationInput.exists?(input.id), "the queued picture must reach its follow-up request"
    assert_equal 2, agent_loop.agent_loop_nodes.count, "only the seed and its one follow-up are needed"
    assert_request_picture(agent_loop)
    apply_round(agent_loop.agent_loop_nodes.find_by!(node_key: "w1"), sse_success("I see the diagram"))
    schedule(agent_loop)
    assert_equal "completed", agent_loop.reload.status
    assert_equal 2, agent_loop.agent_loop_nodes.count
  end

  test "a queued input keeps its picture beside its words in the follow-up request" do
    agent_loop, input = queue_picture(text: "inspect this diagram")
    2.times { schedule(agent_loop) }

    assert_not ConversationInput.exists?(input.id)
    assert_request_picture(agent_loop)
  end

  test "a text-only follow-up sends the existing attachment index line and retains the original binding" do
    agent_loop, input = queue_picture(text: "inspect this diagram", model_ref: "mock-text-only")
    2.times { schedule(agent_loop) }

    follow_up = agent_loop.agent_loop_nodes.find_by!(node_key: "w1")
    request = follow_up.invocation_body("request")
    assert_not ConversationInput.exists?(input.id)
    assert_empty request.content_uploads
    assert_includes request.parts.filter_map { |part| part.text if part.type == Nexus::InputParts::TEXT }.join,
      Conversations::ContextAssembly::AttachmentLine.render(
        @picture, Conversations::ContextAssembly::AttachmentLine::NOT_SHOWN
      )
    assert_equal [@picture.id], follow_up.content_bodies.find_by!(role: "steers").content_uploads.pluck(:id)
  end

  test "a queued picture survives interruption after its input row was consumed" do
    agent_loop, input = queue_picture(text: "")
    2.times { schedule(agent_loop) }
    assert_request_picture(agent_loop)

    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.new(
      agent_loop: agent_loop, acting_user: @human, force: true
    )), :accepted?
    AgentLoops::ConvergeTerminalSteps.call
    assert_predicate AgentLoops::Resume.call(AgentLoops::Resume::Command.new(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?
    schedule(agent_loop)

    assert_request_picture(agent_loop)
    landed = agent_loop.conversation_event_items.where(item_type: "input_materialized")
    assert_equal [input.public_id], landed.map { |item| item.payload.fetch("input_public_id") }
  end

  test "pruned row history keeps queued pictures bound and summaries carry their pointers" do
    agent_loop, = queue_picture(text: "inspect this diagram", tools: [READ_TOOL])
    2.times { schedule(agent_loop) }
    follow_up = agent_loop.agent_loop_nodes.find_by!(node_key: "w1")
    apply_round(follow_up, sse_success("read the file", tool_calls: [
      { id: "read_diagram", name: "read_file", arguments: '{"path":"diagram.txt"}' },
    ]))
    schedule(agent_loop)
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "read_diagram")
    assert_predicate AgentLoops::Parks::Settle.call(
      node: call, trusted: true, content: "x" * 32.kilobytes, outcome: "completed"
    ), :applied?
    next_round = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name, status: "queued").sole
    schedule(agent_loop)
    consumed = next_round.reload.invocation_body("request").entry_payloads
      .select { |entry| entry["type"] == "tool_result_item" }
    assert_equal [["read_diagram", "x" * 32.kilobytes]],
      consumed.map { |entry| entry.fetch("payload").values_at("call_id", "output") },
      "the tool result must reach its first consumer before a later prune can clear it"
    apply_round(next_round, sse_success("I read the file"))
    assert_equal "completed", next_round.reload.status
    grow!(agent_loop, model("after_read", "prompt" => "Continue"))
    next_round = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name, status: "queued").sole
    repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: next_round,
      trigger: Conversations::Compaction::Trigger.wall(next_round,
        overshoot: Conversations::Compaction::Overshoot.bytes(1)))
    assert_predicate repair, :pruned?

    summary = Conversations::Compaction::Serialize.loop_entries(next_round.reload).join("\n")
    assert_includes summary, Conversations::ContextAssembly::AttachmentLine.render(
      @picture, Conversations::ContextAssembly::AttachmentLine::NOT_CARRIED
    )
    schedule(agent_loop)
    request = next_round.reload.invocation_body("request")
    assert_equal [@picture.public_id], request.upload_parts.map(&:public_id)
    assert_equal [@picture.id], request.content_uploads.pluck(:id)
    results = request.entry_payloads.select { |entry| entry["type"] == "tool_result_item" }
    assert_equal [["read_diagram", AgentLoops::RoundReplay::Pairing::CLEARED]],
      results.map { |entry| entry.fetch("payload").values_at("call_id", "output") }
    apply_round(next_round, sse_success("done"))
    schedule(agent_loop)
    assert_equal "completed", agent_loop.reload.status
  end

  private

    def queue_picture(text:, model_ref: "mock-text", tools: nil)
      agent_loop = seed(model("main", "prompt" => "answer first",
        "model" => { "model" => "dev/#{model_ref}" }, **(tools ? { "tools" => tools } : {})))
      result = AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      ))
      assert_predicate result, :accepted?
      schedule(agent_loop)
      accepted = loop_input!(agent_loop, acting_user: @human, text: text,
        delivery_mode: "queue", attachments: [@picture.public_id])
      assert_predicate accepted, :accepted?
      assert_equal "pending", accepted.value.state
      main = agent_loop.agent_loop_nodes.find_by!(node_key: "main")
      apply_round(main, sse_success("first answer"))
      [agent_loop, accepted.value]
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

    def schedule(agent_loop)
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
    end

    def assert_request_picture(agent_loop)
      follow_up = agent_loop.agent_loop_nodes.find_by!(node_key: "w1")
      assert_equal "running", follow_up.status
      request = follow_up.invocation_body("request")
      assert_equal [@picture.public_id], request.upload_parts.map(&:public_id),
        "the exact accepted picture must reach the model and stay bound to its request"
    end
end
