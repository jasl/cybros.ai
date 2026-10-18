require "test_helper"

class Runs::QueuedAttachmentTest < ActiveJob::TestCase
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
    run, input = queue_picture(text: "")
    3.times { schedule(run) }

    assert_not Input.exists?(input.id), "the queued picture must reach its follow-up request"
    assert_equal 2, run.tasks.count, "only the seed and its one follow-up are needed"
    assert_request_picture(run)
    apply_round(run.tasks.find_by!(node_key: "w1"), sse_success("I see the diagram"))
    schedule(run)
    assert_equal "completed", run.reload.status
    assert_equal 2, run.tasks.count
  end

  test "a queued input keeps its picture beside its words in the follow-up request" do
    run, input = queue_picture(text: "inspect this diagram")
    2.times { schedule(run) }

    assert_not Input.exists?(input.id)
    assert_request_picture(run)
  end

  test "a text-only follow-up sends the existing attachment index line and retains the original binding" do
    run, input = queue_picture(text: "inspect this diagram", model_ref: "mock-text-only")
    2.times { schedule(run) }

    follow_up = run.tasks.find_by!(node_key: "w1")
    request = follow_up.invocation_body("request")
    assert_not Input.exists?(input.id)
    assert_empty request.content_uploads
    assert_includes request.parts.filter_map { |part| part.text if part.type == Nexus::InputParts::TEXT }.join,
      Conversations::ContextAssembly::AttachmentLine.render(
        @picture, Conversations::ContextAssembly::AttachmentLine::NOT_SHOWN
      )
    assert_equal [@picture.id], follow_up.content_bodies.find_by!(role: "steers").content_uploads.pluck(:id)
  end

  test "a queued picture survives interruption after its input row was consumed" do
    run, input = queue_picture(text: "")
    2.times { schedule(run) }
    assert_request_picture(run)

    assert_predicate Runs::Pause.call(Runs::Pause::Command.new(
      run: run, acting_user: @human, force: true
    )), :accepted?
    Runs::ConvergeTerminalSteps.call
    assert_predicate Runs::Resume.call(Runs::Resume::Command.new(
      run: run, acting_user: @human
    )), :accepted?
    schedule(run)

    assert_request_picture(run)
    landed = run.event_items.where(item_type: "input_materialized")
    assert_equal [input.public_id], landed.map { |item| item.payload.fetch("input_public_id") }
  end

  test "pruned row history keeps queued pictures bound and summaries carry their pointers" do
    run, = queue_picture(text: "inspect this diagram", tools: [READ_TOOL])
    2.times { schedule(run) }
    follow_up = run.tasks.find_by!(node_key: "w1")
    apply_round(follow_up, sse_success("read the file", tool_calls: [
      { id: "read_diagram", name: "read_file", arguments: '{"path":"diagram.txt"}' },
    ]))
    schedule(run)
    call = run.tasks.find_by!(tool_call_id: "read_diagram")
    assert_predicate Runs::Parks::Settle.call(
      node: call, trusted: true, content: "x" * 32.kilobytes, outcome: "completed"
    ), :applied?
    next_round = run.tasks.where(type: Tasks::ModelTask.sti_name, status: "queued").sole
    schedule(run)
    consumed = next_round.reload.invocation_body("request").entry_payloads
      .select { |entry| entry["type"] == "tool_result_item" }
    assert_equal [["read_diagram", "x" * 32.kilobytes]],
      consumed.map { |entry| entry.fetch("payload").values_at("call_id", "output") },
      "the tool result must reach its first consumer before a later prune can clear it"
    apply_round(next_round, sse_success("I read the file"))
    assert_equal "completed", next_round.reload.status
    grow!(run, model("after_read", "prompt" => "Continue"))
    next_round = run.tasks.where(type: Tasks::ModelTask.sti_name, status: "queued").sole
    repair = Conversations::Compaction::Arm.call(run: run, node: next_round,
      trigger: Conversations::Compaction::Trigger.wall(next_round,
        overshoot: Conversations::Compaction::Overshoot.bytes(1)))
    assert_predicate repair, :pruned?

    summary = Conversations::Compaction::Serialize.loop_entries(next_round.reload).join("\n")
    assert_includes summary, Conversations::ContextAssembly::AttachmentLine.render(
      @picture, Conversations::ContextAssembly::AttachmentLine::NOT_CARRIED
    )
    schedule(run)
    request = next_round.reload.invocation_body("request")
    assert_equal [@picture.public_id], request.upload_parts.map(&:public_id)
    assert_equal [@picture.id], request.content_uploads.pluck(:id)
    results = request.entry_payloads.select { |entry| entry["type"] == "tool_result_item" }
    assert_equal [["read_diagram", Runs::RoundReplay::Pairing::CLEARED]],
      results.map { |entry| entry.fetch("payload").values_at("call_id", "output") }
    apply_round(next_round, sse_success("done"))
    schedule(run)
    assert_equal "completed", run.reload.status
  end

  private

    def queue_picture(text:, model_ref: "mock-text", tools: nil)
      run = seed(model("main", "prompt" => "answer first",
        "model" => { "model" => "dev/#{model_ref}" }, **(tools ? { "tools" => tools } : {})))
      result = Runs::Start.call(Runs::Start::Command.new(
        run: run, acting_user: @human
      ))
      assert_predicate result, :accepted?
      schedule(run)
      accepted = loop_input!(run, acting_user: @human, text: text,
        delivery_mode: "queue", attachments: [@picture.public_id])
      assert_predicate accepted, :accepted?
      assert_equal "pending", accepted.value.state
      main = run.tasks.find_by!(node_key: "main")
      apply_round(main, sse_success("first answer"))
      [run, accepted.value]
    end

    def apply_round(node, response)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == node.selected_model_invocation_id
      end
      assert_not_nil admitted
      apply_via(admitted.attempt, response)
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
    end

    def schedule(run)
      Runs::ScheduleReady.call(run_id: run.id)
      clear_enqueued_jobs
    end

    def assert_request_picture(run)
      follow_up = run.tasks.find_by!(node_key: "w1")
      assert_equal "running", follow_up.status
      request = follow_up.invocation_body("request")
      assert_equal [@picture.public_id], request.upload_parts.map(&:public_id),
        "the exact accepted picture must reach the model and stay bound to its request"
    end
end
