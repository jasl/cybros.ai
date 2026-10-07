require "test_helper"

class Conversations::ContextAssemblyToolPicturesTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  Assembly = Conversations::ContextAssembly
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent, compaction_policy: { "mode" => "kernel" })
    @executor = TaskExecutor.address_for(@agent)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
      answering_user: @agent)
  end

  test "later turns carry one ordered deduplicated picture message after every result and bind its rows" do
    first, second = capture("first.png"), capture("second.png")
    log = capture("trace.log", content_type: "text/plain", bytes: "trace output")
    complete_capture_turn([[second, first, second], [first, log]])

    _, agent_run = next_turn
    request = request_of(loop_node(agent_run, "r1"))
    entries = payloads(request)
    results = entries.each_index.select { |index| entries[index]["type"] == "tool_result_item" }
    assert_equal %w[call_0 call_1], results.map { |index| entries[index].dig("payload", "call_id") }
    assert_equal ["saved 0", "saved 1"], results.map { |index| entries[index].dig("payload", "output") }
    assert_equal picture_entry(second, first), entries.fetch(results.last + 1)
    assert_equal 1, entries.count { |entry| upload_ids([entry]).any? }
    assert_equal [second.public_id, first.public_id], upload_ids(entries)
    assert_equal [first.public_id, second.public_id].sort, request.content_uploads.map(&:public_id).sort
    refute_includes entries.to_json, log.public_id,
      "a non-image capture stays out even when its resource link claims image/png"

    built = build(loop_attempt(agent_run))
    assert_predicate built, :built?, built.refusal.inspect
    wire = JSON.parse(built.request.payload).fetch("input")
    images = wire.flat_map { |entry| entry.fetch("content", []) }.select { |part| part["type"] == "input_image" }
    assert_equal 2, images.length
    assert images.all? { |part| part.fetch("image_url").start_with?("data:image/png;base64,") },
      "the later request resolves the bound capture bytes through the provider builder"
  end

  test "each later model re-places the retained captures as native images or index lines" do
    png = capture("supported.png")
    heic = capture("unsupported.heic", content_type: "image/heic")
    _, original_loop = complete_capture_turn([[png, heic]])

    text_turn, text_loop = next_turn(model_ref: "mock-text-only")
    text_request = request_of(loop_node(text_loop, "r1"))
    text_entries = payloads(text_request)
    assert_empty upload_ids(text_entries)
    assert_empty text_request.content_uploads
    assert_equal [png, heic].map { |upload| Assembly::AttachmentLine.render(upload, Assembly::AttachmentLine::NOT_SHOWN) },
      attachment_lines(text_entries)
    source = original_loop.agent_run_tasks.find_by!(tool_call_id: "call_0").output_body
    assert_equal [png.public_id, heic.public_id].sort, source.content_uploads.map(&:public_id).sort,
      "text-only placement does not replace the original capture bindings"
    finish_turn(text_turn, text_loop)

    _, vision_loop = next_turn
    vision_request = request_of(loop_node(vision_loop, "r1"))
    assert_equal [png.public_id], upload_ids(payloads(vision_request))
    assert_equal [png.public_id], vision_request.content_uploads.map(&:public_id)
    assert_equal [Assembly::AttachmentLine.render(heic, "this model does not take image/heic")],
      attachment_lines(payloads(vision_request))
  end

  test "a later turn replays the first-consumed capture after an in-turn summary" do
    picture = capture("after-summary.png")
    complete_capture_turn([[picture]], compact: true)

    _, agent_run = next_turn
    request = request_of(loop_node(agent_run, "r1"))
    entries = payloads(request)
    result_index = entries.index { |entry| entry.dig("payload", "call_id") == "call_0" && entry["type"] == "tool_result_item" }
    assert_equal "saved 0", entries.fetch(result_index).dig("payload", "output")
    assert_equal picture_entry(picture), entries.fetch(result_index + 1)
    assert_equal [picture.public_id], request.content_uploads.map(&:public_id)
    assert_includes entries.to_json, "COMPACTED HISTORY"
    refute_includes entries.to_json, "Mock: inspecting captures"
  end

  test "a subsequent prune removes the consumed post-summary capture from later turns" do
    picture = capture("consumed.png")
    turn, agent_run, consumer = capture_round([[picture]], compact: true, result_padding: "x" * 4096)
    assert_equal [picture.public_id], request_of(consumer).content_uploads.map(&:public_id)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "kernel", tip: kernel_tip(consumer, [consumer]),
      steps: [AgentRuns::Tasks::Step.inheriting(consumer, key: "after", prompt: "continue")]
    ))
    assert_predicate appended, :applied?
    apply_via(loop_attempt(agent_run), sse_success("capture consumed"))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    after = loop_node(agent_run, "after")
    repair = Conversations::Compaction::Arm.call(agent_run: agent_run, node: after,
      trigger: Conversations::Compaction::Trigger.wall(after,
        overshoot: Conversations::Compaction::Overshoot.bytes(1)))
    assert_predicate repair, :pruned?
    schedule_loop!(agent_run)
    finish_turn(turn, agent_run)

    _, later_loop = next_turn
    request = request_of(loop_node(later_loop, "r1"))
    entries = payloads(request)
    assert_equal [AgentRuns::RoundReplay::Pairing::CLEARED],
      entries.select { |entry| entry["type"] == "tool_result_item" }.map { |entry| entry.dig("payload", "output") }
    assert_empty upload_ids(entries)
    assert_empty request.content_uploads
    refute_includes entries.to_json, "consumed.png"
  end

  test "execution retention leaves the question and final answer without promoting tool captures" do
    picture = capture("expired.png")
    _, original_loop = complete_capture_turn([[picture]])
    @account.update!(execution_details_retention_days: 90)
    original_loop.update!(completed_at: 100.days.ago)
    pruned = Conversations::ExecutionDetails::Prune.call(account: @account, batch: 20)
    assert_equal 1, pruned[:pruned]
    assert original_loop.reload.details_pruned_at
    assert_empty original_loop.agent_run_tasks.reload

    _, later_loop = next_turn
    request = request_of(loop_node(later_loop, "r1"))
    entries = payloads(request)
    assert_includes entries.to_json, "inspect the captures"
    assert_includes entries.to_json, "Mock: captures inspected"
    assert_empty upload_ids(entries)
    assert_empty request.content_uploads
    refute entries.any? { |entry| %w[tool_call_item tool_result_item].include?(entry["type"]) }
    refute_includes entries.to_json, "expired.png"
  end

  test "token and byte boundaries keep or drop the entire captured round with its image" do
    picture = capture("budgeted.png")
    complete_capture_turn([[picture]])
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    profile = DevModelLane.profile_with(selection.execution_profile, token_counter: nil)
    options = { conversation: @conversation.reload, answerer: @agent, profile: profile,
                carries: Assembly::AttachmentLine.carries_for(selection) }
    history = Assembly::ChatHistory.call(**options)
    capture_index = history.segments.index { |segment| segment.call_items.any? }
    assert capture_index
    captured_and_newer = history.segments.drop(capture_index)
    entries = Nexus::InputEntries.for(captured_and_newer.flat_map(&:elements))
    assert_equal [picture.public_id], upload_ids(entries)

    text_tokens = captured_and_newer.flat_map(&:priced_texts).sum { |text| (text.bytesize / 4.0).ceil }
    assert_equal 2500, profile.input_media.fetch("image").token_cost
    bounds = {
      token_budget: text_tokens + 2500,
      byte_budget: entries.sum { |entry| Nexus::CanonicalJson.bytesize(entry) },
    }
    bounds.each do |unit, bound|
      at_boundary = Assembly::ChatHistory.call(**options, **{ unit => bound })
      included = Nexus::InputEntries.for(at_boundary.segments.flat_map(&:elements))
      assert_equal [picture.public_id], upload_ids(included), "#{unit}: exactly enough funds the picture"
      assert_equal 1, included.count { |entry| entry["type"] == "tool_result_item" }

      below = Assembly::ChatHistory.call(**options, **{ unit => bound - 1 })
      excluded = Nexus::InputEntries.for(below.segments.flat_map(&:elements))
      assert_equal "budget_exceeded", below.skipped_reason
      assert_empty upload_ids(excluded), "#{unit}: no orphan picture survives its excluded round"
      refute excluded.any? { |entry| %w[tool_call_item tool_result_item].include?(entry["type"]) }
      assert_includes excluded.to_json, "Mock: captures inspected", "the newer final answer still fits"
    end
  end

  private

    def capture(filename, content_type: "image/png", bytes: PNG)
      @account.content_uploads.create!(creating_executor: @executor,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename,
          content_type: content_type, identify: false))
    end

    def complete_capture_turn(uploads, **options)
      turn, agent_run, = capture_round(uploads, **options)
      finish_turn(turn, agent_run)
      [turn, agent_run]
    end

    def capture_round(uploads, compact: false, result_padding: "")
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, text: "inspect the captures")
      schedule_loop!(agent_run)
      calls = uploads.each_index.map { |index| { id: "call_#{index}", name: "read_file", arguments: "{}" } }
      run_loop_round!(agent_run, sse_success("inspecting captures", tool_calls: calls))
      uploads.each_with_index do |rows, index|
        task = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_#{index}")
        claimed = Executors::Claim.call(Executors::Claim::Command.new(
          agent_run: agent_run, task_key: task.node_key, executor: @executor
        ))
        assert_predicate claimed, :accepted?
        # Link metadata is descriptive. Only the bound upload's actual type
        # decides whether a capture becomes a picture, including on later turns.
        links = rows.map do |upload|
          { "type" => "resource_link", "uri" => "nexus://uploads/#{upload.public_id}",
            "name" => upload.filename.to_s,
            "mimeType" => upload.content_type.start_with?("image/") ? "text/plain" : "image/png" }
        end
        committed = Executors::Commit.call(Executors::Commit::Command.new(
          agent_run: agent_run, task_key: task.node_key, executor: @executor,
          claim_token: claimed.value.claim_token,
          content: [{ "type" => "text", "text" => "saved #{index}#{result_padding}" }, *links],
          structured_content: nil, result_type: nil, outcome: "completed", is_error: false,
          title: nil, metadata: nil
        ))
        assert_predicate committed, :applied?
      end
      consumer = agent_run.agent_run_tasks.where(continuation_source: "round").order(:id).last
      if compact
        repair = Conversations::Compaction::Arm.call(agent_run: agent_run, node: consumer,
          trigger: Conversations::Compaction::Trigger.manual(user: @human))
        assert_equal "kernel", repair.mode
        schedule_loop!(agent_run)
        run_loop_round!(agent_run, sse_success("COMPACTED HISTORY"))
      end
      schedule_loop!(agent_run)
      assert_equal "running", consumer.reload.status
      [turn, agent_run, consumer]
    end

    def finish_turn(turn, agent_run)
      run_loop_round!(agent_run, sse_success("captures inspected"))
      Conversations::Turns::Converge.call
      clear_enqueued_jobs
      assert_equal "completed", turn.reload.status
    end

    def next_turn(model_ref: "mock-text")
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, text: "what did the captures show?",
        model_ref: model_ref)
      schedule_loop!(agent_run)
      [turn, agent_run]
    end

    def request_of(node)
      ContentBody.find_by!(model_invocation_id: node.reload.selected_model_invocation_id, role: "request")
    end

    def payloads(body)
      body.content_body_entries.map { |entry| entry.content_fragment.payload }
    end

    def picture_entry(*uploads)
      { "role" => "user", "parts" => uploads.map { |upload| { "type" => "upload", "upload_public_id" => upload.public_id } } }
    end

    def upload_ids(entries)
      entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["upload_public_id"] } }
    end

    def attachment_lines(entries)
      entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }
        .select { |text| text.start_with?("[Attachment:") }
    end
end
