require "test_helper"

class AgentRuns::PdfAttachmentsTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  PDF = "%PDF-1.7\ncaptured document contents\n%%EOF\n".freeze
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze
  Assembly = Conversations::ContextAssembly

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

  test "current and later turns carry deduplicated mixed captures after all results using the actual MIME" do
    with_pdf_model do
      document = capture("report.pdf")
      image = capture("chart.png", bytes: PNG, content_type: "image/png")
      ordinary = capture("notes.txt", bytes: "ordinary capture", content_type: "text/plain")
      turn, agent_run, consumer = capture_round([[document, image, document], [ordinary, image]])
      assert_capture_request(consumer, [document, image], result_count: 2)
      refute_includes request_of(consumer).entry_payloads.to_json, ordinary.public_id,
        "a text capture claiming application/pdf must not become native media"
      assert_pdf_wire(consumer, document)
      finish_turn(turn, agent_run)

      _, later_loop = next_turn
      later = loop_node(later_loop, "r1")
      assert_capture_request(later, [document, image], result_count: 2)
      assert_pdf_wire(later, document)
      assert_equal [document.id, image.id, ordinary.id].sort,
        agent_run.agent_run_tasks.where.not(tool_call_id: nil).flat_map { |node| node.output_body.content_uploads.map(&:id) }.uniq.sort
    end
  end

  test "unsupported current placement leaves the captured PDF available to a capable later model" do
    with_pdf_model do
      document = capture("later.pdf")
      turn, agent_run, consumer = capture_round([[document]], model_ref: "mock-text-only")
      request = request_of(consumer)
      assert_empty request.content_uploads
      assert_empty upload_ids(request.entry_payloads)
      assert_includes request.entry_payloads.to_json, "nexus://uploads/#{document.public_id}"
      assert_includes request.entry_payloads.to_json, "file content is available through attachment tools"
      assert_equal [document.id], agent_run.agent_run_tasks.find_by!(tool_call_id: "call_0")
        .output_body.content_uploads.map(&:id)
      finish_turn(turn, agent_run)

      _, later_loop = next_turn
      assert_capture_request(loop_node(later_loop, "r1"), [document])
    end
  end

  test "an in-turn summary preserves the current fan PDF for its first consumption and later history" do
    with_pdf_model do
      document = capture("after-summary.pdf")
      turn, agent_run, consumer = capture_round([[document]], compact: true)
      assert_capture_request(consumer, [document])
      entries = request_of(consumer).entry_payloads
      assert_includes entries.to_json, "COMPACTED HISTORY"
      refute_includes entries.to_json, "Mock: inspecting captures"
      finish_turn(turn, agent_run)

      _, later_loop = next_turn
      later = loop_node(later_loop, "r1")
      assert_capture_request(later, [document])
      assert_includes request_of(later).entry_payloads.to_json, "COMPACTED HISTORY"
      refute_includes request_of(later).entry_payloads.to_json, "Mock: inspecting captures"
    end
  end

  test "a later prune clears a consumed post-summary PDF together with its result" do
    with_pdf_model do
      document = capture("consumed.pdf")
      turn, agent_run, consumer = capture_round([[document]], compact: true, result_padding: "x" * 4096)
      assert_equal [document.id], request_of(consumer).content_uploads.map(&:id)
      appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
        agent_run: agent_run, origin: "kernel", tip: kernel_tip(consumer, [consumer]),
        steps: [AgentRuns::Tasks::Step.inheriting(consumer, key: "after", prompt: "continue")]
      ))
      assert_predicate appended, :applied?
      apply_via(loop_attempt(agent_run), sse_success("PDF consumed"))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      after = loop_node(agent_run, "after")
      repair = Conversations::Compaction::Arm.call(agent_run: agent_run, node: after,
        trigger: Conversations::Compaction::Trigger.wall(after,
          overshoot: Conversations::Compaction::Overshoot.bytes(1)))
      assert_predicate repair, :pruned?
      schedule_loop!(agent_run)
      assert_cleared_request(after)
      finish_turn(turn, agent_run)

      _, later_loop = next_turn
      request = request_of(loop_node(later_loop, "r1"))
      assert_cleared_request(loop_node(later_loop, "r1"))
      refute_includes request.entry_payloads.to_json, document.public_id
      refute_includes request.entry_payloads.to_json, "consumed.pdf"
    end
  end

  test "peer history and execution retention do not promote tool PDFs into the retained final reply" do
    with_pdf_model do
      document = capture("expired.pdf")
      turn, agent_run, = capture_round([[document]])
      finish_turn(turn, agent_run)
      peer = create_agent_member(display_name: "PDF peer", agent_identifier: "pdf-peer")
      history = Assembly::ChatHistory.call(conversation: @conversation.reload, answerer: peer)
      entries = Nexus::InputEntries.for(history.segments.flat_map(&:elements))
      assert_empty upload_ids(entries)
      refute entries.any? { |entry| %w[tool_call_item tool_result_item].include?(entry["type"]) }
      assert_includes entries.to_json, "Mock: captures inspected"

      @account.update!(execution_details_retention_days: 90)
      agent_run.update!(completed_at: 100.days.ago)
      pruned = Conversations::ExecutionDetails::Prune.call(account: @account, batch: 20)
      assert_equal 1, pruned[:pruned]
      assert agent_run.reload.details_pruned_at
      assert_empty agent_run.agent_run_tasks.reload
      _, later_loop = next_turn
      request = request_of(loop_node(later_loop, "r1"))
      assert_empty request.content_uploads
      assert_empty upload_ids(request.entry_payloads)
      assert_includes request.entry_payloads.to_json, "inspect the captures"
      assert_includes request.entry_payloads.to_json, "Mock: captures inspected"
      refute_includes request.entry_payloads.to_json, "expired.pdf"
    end
  end

  private

    def with_pdf_model(&block)
      current = ModelCatalog.current
      row = current.models.fetch("dev/mock-text")
      pdf = row.merge("capabilities" => row.fetch("capabilities").merge("input_modalities" => %w[image file]))
      catalog = current.with(models: current.models.merge("dev/mock-text" => pdf))
      ModelCatalog::CatalogValidation.validate_change(catalog.models, catalog.selectors, "dev/mock-text", catalog.providers)
      ModelCatalog.stub(:current, catalog, &block)
    end

    def capture(filename, bytes: PDF, content_type: "application/pdf")
      @account.content_uploads.create!(creating_executor: @executor,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename,
          content_type: content_type, identify: false))
    end

    def capture_round(uploads, compact: false, result_padding: "", model_ref: "mock-text")
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, text: "inspect the captures",
        model_ref: model_ref)
      schedule_loop!(agent_run)
      calls = uploads.each_index.map { |index| { id: "call_#{index}", name: "read_file", arguments: "{}" } }
      run_loop_round!(agent_run, sse_success("inspecting captures", tool_calls: calls))
      uploads.each_with_index { |rows, index| commit_captures(agent_run, rows, index, result_padding) }
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

    def commit_captures(agent_run, rows, index, padding)
      task = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_#{index}")
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: agent_run, task_key: task.node_key, executor: @executor
      ))
      assert_predicate claimed, :accepted?
      # Descriptive link MIME is deliberately wrong in both directions:
      # native carriage is selected from the bound upload's detected type.
      links = rows.map do |upload|
        { "type" => "resource_link", "uri" => "nexus://uploads/#{upload.public_id}",
          "name" => upload.filename.to_s,
          "mimeType" => upload.content_type == "application/pdf" ? "image/png" : "application/pdf" }
      end
      committed = Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: agent_run, task_key: task.node_key, executor: @executor,
        claim_token: claimed.value.claim_token,
        content: [{ "type" => "text", "text" => "saved #{index}#{padding}" }, *links],
        structured_content: nil, result_type: nil, outcome: "completed", is_error: false,
        title: nil, metadata: nil
      ))
      assert_predicate committed, :applied?
    end

    def assert_capture_request(node, uploads, result_count: 1)
      request = request_of(node)
      entries = request.entry_payloads
      results = entries.each_index.select { |index| entries[index]["type"] == "tool_result_item" }
      assert_equal result_count, results.length
      assert_equal result_count.times.map { |index| "saved #{index}" },
        results.map { |index| entries[index].dig("payload", "output") }
      assert_equal({ "role" => "user", "parts" => uploads.map do |upload|
        { "type" => "upload", "upload_public_id" => upload.public_id }
      end }, entries.fetch(results.last + 1))
      assert_equal uploads.map(&:public_id), upload_ids(entries)
      assert_equal 1, entries.count { |entry| upload_ids([entry]).any? }
      assert_equal uploads.map(&:id).sort, request.content_uploads.map(&:id).sort
    end

    def assert_pdf_wire(node, document)
      invocation = ModelInvocation.find(node.selected_model_invocation_id)
      built = ModelRequests::Build.call(invocation: invocation,
        profile: DevModelLane.profile_for_invocation(invocation),
        base_url: ModelCatalog.provider_base_url(invocation.provider_id), host: "solid_queue")
      assert_predicate built, :built?, built.refusal.inspect
      content = JSON.parse(built.request.payload).fetch("input").flat_map { |entry| entry.fetch("content", []) }
      file = content.select { |part| part["type"] == "input_file" }.sole
      assert_equal document.filename.to_s, file.fetch("filename")
      assert_equal "data:application/pdf;base64,#{Base64.strict_encode64(PDF)}", file.fetch("file_data")
    end

    def assert_cleared_request(node)
      request = request_of(node)
      assert_equal [AgentRuns::RoundReplay::Pairing::CLEARED],
        request.entry_payloads.select { |entry| entry["type"] == "tool_result_item" }
          .map { |entry| entry.dig("payload", "output") }
      assert_empty request.content_uploads
      assert_empty upload_ids(request.entry_payloads)
    end

    def finish_turn(turn, agent_run)
      run_loop_round!(agent_run, sse_success("captures inspected"))
      Conversations::Turns::Converge.call
      clear_enqueued_jobs
      assert_equal "completed", turn.reload.status
    end

    def next_turn
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, text: "what did the captures show?")
      schedule_loop!(agent_run)
      [turn, agent_run]
    end

    def request_of(node)
      ContentBody.find_by!(model_invocation_id: node.reload.selected_model_invocation_id, role: "request")
    end

    def upload_ids(entries)
      entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["upload_public_id"] } }
    end
end
