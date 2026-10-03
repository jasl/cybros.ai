require "test_helper"

# THE IMAGES RIDER: a tool result's PICTURE — a capture the result names with a `resource_link`
# whose bound row is an image — rides the NEXT round as ONE picture-only user message after the
# round's LAST result, once per round however many results captured one; placed per part at assembly
# against the round's selection (the catalog admits `image` → the `upload` part stays and the seal
# binds the row; else the RULED index line in its place, nothing bound); a non-media capture adds
# neither a part nor a line. Read through the SEALED request, never the renderer alone.
class AgentLoops::CaptureRiderTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )
  AttachmentLine = Conversations::ContextAssembly::AttachmentLine

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "two captures in one round ride one picture-only message after the last result, bound by the seal" do
    first, second = picture("one.png"), picture("two.png")
    continuation, entries = continuation_after([first, second])

    assert_equal [
      ["result", "call_0", "saved 0"],
      ["result", "call_1", "saved 1"],
      ["user", [["upload", first.public_id], ["upload", second.public_id]]],
    ], shape(entries.last(3)), "both results, then ONE picture message with both parts, in result order"
    assert_equal 2, entries.count { |entry| entry["type"] == "tool_result_item" }
    assert_equal [first.public_id, second.public_id].sort, request_of(continuation).content_uploads.map(&:public_id).sort,
      "the seal binds the placed rows"
    words = entries.reject { |entry| entry["role"] == "user" && entry.dig("parts", 0, "type") == "upload" }
    refute_match(/#{first.public_id}|#{second.public_id}/, JSON.generate(words), "no upload id reaches the model as words")
  end

  test "on a text-only row the round seals the ruled line in each picture's place and binds nothing" do
    first, second = picture("one.png"), picture("two.png")
    continuation, entries = continuation_after([first, second], model: "dev/mock-text-only")

    lines = [first, second].map { |upload| ["text", AttachmentLine.render(upload, AttachmentLine::NOT_SHOWN)] }
    assert_equal [["result", "call_0", "saved 0"], ["result", "call_1", "saved 1"], ["user", lines]], shape(entries.last(3))
    assert_empty request_of(continuation).content_uploads
    assert_match(/image content omitted: this model does not support image input/, entries.last.dig("parts", 0, "text"))
  end

  test "a non-media capture adds neither a part nor a line, and a round with no picture adds no message" do
    log = @account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("line one\n"), filename: "trace.log",
        content_type: "text/plain", identify: false)
    )
    square = picture("square.png")
    continuation, entries = continuation_after([log, square])
    assert_equal [["result", "call_0", "saved 0"], ["result", "call_1", "saved 1"],
                  ["user", [["upload", square.public_id]]]], shape(entries.last(3))
    assert_equal [square.public_id], request_of(continuation).content_uploads.map(&:public_id)
    refute_includes JSON.generate(entries), log.public_id

    _, alone = continuation_after([nil])
    assert_equal ["result", "call_0", "saved 0"], shape([alone.last]).first, "a text-only result closes the list"
  end

  test "a cleared round keeps its calls and drops its pictures with its results" do
    square = picture("square.png")
    continuation, = continuation_after([square])
    round1 = continuation.agent_loop.agent_loop_nodes.find_by!(node_key: "round1")
    fan = AgentLoops::RoundReplay.fans_of([round1]).fetch(round1.id)

    kept = AgentLoops::RoundReplay.call(round1, fan_by_call_id: fan)
    assert_equal [square.public_id], kept.picture.upload_public_ids
    cleared = AgentLoops::RoundReplay.call(round1, fan_by_call_id: fan, cleared: true)
    assert_nil cleared.picture
    assert_equal [AgentLoops::RoundReplay::Pairing::CLEARED], cleared.result_items.map { |item| item.payload["output"] }
  end

  test "a summary keeps the current capture through sealing and later row reconstruction" do
    square = picture("square.png")
    continuation, entries = continuation_after([square], compact: true)

    assert_equal [["result", "call_0", "saved 0"], ["user", [["upload", square.public_id]]]], shape(entries.last(2))
    assert_equal [square.public_id], request_of(continuation).content_uploads.map(&:public_id)
    assert_includes entries.first.dig("parts", 0, "text"), "COMPACTED HISTORY"
    refute_includes entries.filter_map { |entry| entry.dig("parts", 0, "text") }, "Mock: calling"

    readers = AgentLoops::InputComposition.readers_by_round([continuation.reload])
    source = AgentLoops::InputComposition.source_round(continuation)
    queries = []
    capture = lambda do |*, payload|
      if !payload[:cached] && payload.fetch(:sql).match?(/\ASELECT .*FROM "content_bodies"/m)
        queries << payload.fetch(:binds).map { |bind| [bind.name, bind.value_for_database] }
      end
    end
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
      ApplicationRecord.uncached { AgentLoops::InputComposition.compacted_pairs_by_round(readers) }
    end
    assert readers.fetch(continuation.id).compacted_source.association(:tool_calls_body).loaded?
    assert queries.any? { |binds| binds.include?(["role", "output"]) }, "the current fan's body is loaded"
    refute queries.any? { |binds|
      (binds.include?(["agent_loop_node_id", source.id]) ||
        binds.include?(["model_invocation_id", source.selected_model_invocation_id])) &&
        binds.any? { |name, value| name == "role" && %w[output reasoning_trace].include?(value) }
    }, "a summary's paired replay never reloads the replaced source answer or trace"

    reader = node(continuation.agent_loop, "m2")
    AgentLoopNode.where(id: reader.id).update_all(compaction: { "pruned_before" => continuation.node_key })
    rebuilt = AgentLoops::InputComposition.call(node: reader.reload, input: reader.input_value)
    assert_predicate rebuilt, :composed?
    assert_equal [square.public_id], rebuilt.uploads.map(&:public_id)
    rebuilt_entries = Nexus::InputEntries.for(rebuilt.elements)
    assert_equal 1, rebuilt_entries.count { |entry| entry.dig("payload", "output") == "saved 0" }
    assert_equal 1, rebuilt_entries.count { |entry| entry.dig("parts", 0, "upload_public_id") == square.public_id }

    transcript = Conversations::Compaction::Serialize.loop_entries(reader).join("\n")
    assert_includes transcript, "COMPACTED HISTORY"
    assert_includes transcript, "Tool read_file (completed, ok)"
    assert_includes transcript, "not carried; re-read it if needed"
    refute_includes transcript, "saved 0"
    refute_includes transcript, "Mock: calling"

    AgentLoopNode.where(id: reader.id).update_all(compaction: { "pruned_before" => reader.node_key })
    cleared = AgentLoops::InputComposition.call(node: reader.reload, input: reader.input_value)
    assert_predicate cleared, :composed?
    assert_empty cleared.uploads, "a later prune clears the already-consumed pair and its capture together"
    cleared_entries = Nexus::InputEntries.for(cleared.elements)
    assert_equal [AgentLoops::RoundReplay::Pairing::CLEARED],
      cleared_entries.select { |entry| entry["type"] == "tool_result_item" }.map { |entry| entry.dig("payload", "output") }
    refute cleared_entries.any? { |entry| entry.dig("parts", 0, "upload_public_id") == square.public_id }
  end

  private

    def picture(filename)
      @account.content_uploads.create!(
        creating_user: @human,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: filename, content_type: "image/png")
      )
    end

    def link(upload)
      { "type" => "resource_link", "uri" => "nexus://uploads/#{upload.public_id}", "name" => upload.filename.to_s }
    end

    def declared(name)
      { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
    end

    def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

    def request_of(node)
      ContentBody.find_by!(model_invocation_id: node.reload.selected_model_invocation_id, role: "request")
    end

    def start!(agent_loop)
      AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      agent_loop.reload
    end

    def attempt_of(agent_loop, key)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == node(agent_loop, key).selected_model_invocation_id
      end
      raise "#{key} not admitted" if admitted.nil?

      clear_enqueued_jobs
      admitted.attempt
    end

    # A round calling `read_file` (the suite runner serves it) once per
    # element; each call settled as the person's own resolution with a
    # text block and, for a row, a link to it; then the continuation's
    # request BUILT and its sealed entries read.
    def continuation_after(uploads, model: "dev/mock-text", compact: false)
      row = { "model" => model }
      agent_loop = seed(model("round1", "prompt" => "go", "model" => row, "tools" => [declared("read_file")]),
        model("m2", "prompt" => "then", "model" => row))
      start!(agent_loop)
      calls = uploads.each_index.map { |index| { id: "call_#{index}", name: "read_file", arguments: "{}" } }
      apply_via(attempt_of(agent_loop, "round1"), sse_success("calling", tool_calls: calls))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(agent_loop)
      uploads.each_with_index do |upload, index|
        call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_#{index}")
        assert_equal "dispatched", call.status
        content = [{ "type" => "text", "text" => "saved #{index}" }, (link(upload) if upload)].compact
        assert_predicate AgentLoops::Parks::Settle.call(node: call, trusted: true, creator: @human,
          content: content, outcome: "completed"), :applied?
      end
      if compact
        repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: node(agent_loop, "r1"),
          trigger: Conversations::Compaction::Trigger.manual(user: @human))
        assert_equal "kernel", repair.mode
        schedule_loop!(agent_loop)
        run_loop_round!(agent_loop, sse_success("COMPACTED HISTORY"))
      end
      schedule_loop!(agent_loop)
      continuation = node(agent_loop, "r1")
      assert_equal "running", continuation.status, "the model reads the results on the next round"
      build(attempt_of(agent_loop, "r1"))
      [continuation, round_request_entries(continuation)]
    end

    def shape(payloads)
      payloads.map do |payload|
        case payload["type"]
        when "tool_result_item"
          ["result", payload.dig("payload", "call_id"), payload.dig("payload", "output")]
        else
          [payload["role"], payload["parts"].map { |part| [part["type"], part["upload_public_id"] || part["text"]] }]
        end
      end
    end
end
