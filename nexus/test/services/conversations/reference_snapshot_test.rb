require "test_helper"

class Conversations::ReferenceSnapshotTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
      answering_user: @agent)
  end

  test "a side freezes the live turn's seed, persisted tool value and pending work without an execution graph" do
    turn, run = running!("inspect the long task")
    tools!(run, %w[landed pending])
    settle!(run, "landed", "FIRST VALUE")

    side = fork!
    reference = side.conversation_turns.sole
    before = entries(side)
    assert_predicate reference, :reference?
    assert_equal turn.public_id, reference.forked_from_turn_public_id
    assert_equal turn.active_variant.public_id, reference.forked_from_variant_public_id
    assert_equal "completed", reference.status
    assert_equal "running", turn.reload.status
    assert_equal 0, AgentRun.where(conversation_turn_variant: reference.conversation_turn_variants).count
    assert_nil reference.active_variant.agent_run
    assert_nil reference.active_variant.model_invocation
    assert_equal %w[landed pending], before.filter_map { |entry| entry.dig("payload", "call_id") if entry["type"] == "tool_call_item" }
    results = before.select { |entry| entry["type"] == "tool_result_item" }.map { |entry| entry.fetch("payload") }
    assert_equal "FIRST VALUE", results.first.fetch("output")
    assert_includes results.last.fetch("output"), "no result was available"
    assert_includes results.last.fetch("output"), "parent still owns"
    assert_not results.last["is_error"], "pending work is a snapshot fact, not an execution error"
    assert_includes before.to_json, "inspect the long task"
    assert_includes before.to_json, "run status running"

    settle!(run, "pending", "LATER VALUE")
    schedule_loop!(run)
    run_loop_round!(run, sse_success("PARENT FINISHED"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_equal before, entries(side), "later source settlement cannot rewrite the reference"
    assert_not_includes entries(side).to_json, "LATER VALUE"
    assert_not_includes entries(side).to_json, "PARENT FINISHED"
    display = reference.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_includes display, "FIRST VALUE", "the existing turn read can reread a summary's pointer"
  end

  test "a first-round invocation published before run adoption contributes no unowned calls" do
    _turn, run = running!("first question")
    apply_via(loop_attempt(run), sse_success("not adopted", tool_calls: [
      { id: "unadopted", name: "read_file", arguments: "{}" },
    ]))
    assert_equal "running", loop_node(run, "r1").status

    side = fork!
    captured = entries(side)

    assert_includes captured.to_json, "first question"
    assert_not_includes captured.to_json, "unadopted"
    assert_not captured.any? { |entry| entry["type"] == "tool_call_item" }
    assert_equal 0, AgentRun.where(conversation_turn_variant: side.conversation_turns.sole.conversation_turn_variants).count
    body = side.conversation_turns.sole.active_variant.content_bodies.find_by!(role: "reference")
    summary = Conversations::ReferenceSnapshot.summary_entries(body).join("\n")
    assert_includes summary, "first question"
    assert_not_includes summary, "not adopted"
    assert_not_includes summary, "unadopted"
  end

  test "the reference cannot become active work or be removed as an editable tail" do
    _turn, _run = running!("first question")
    side = fork!
    reference = side.conversation_turns.sole

    assert_not_predicate reference, :tail?
    result = Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
      conversation: side, turn_public_id: reference.public_id, acting_user: @human
    ))
    assert_equal :branch_required, result.outcome
    assert_raises(ActiveRecord::RecordInvalid) do
      ConversationTurnVariant.create!(account: @account, conversation_turn: reference,
        position: 1, source: "inference", status: "running")
    end
    assert_raises(ActiveRecord::RecordInvalid) { reference.active_variant.update!(status: "running") }
    assert_raises(ActiveRecord::RecordNotDestroyed) { reference.destroy! }
  end

  test "summary input points to the copied turn without paraphrasing tool values" do
    _turn, run = running!("inspect source")
    tools!(run, ["landed"])
    settle!(run, "landed", "VALUE THAT MUST STAY OUT OF A SUMMARY")
    side = fork!
    reference = side.conversation_turns.sole
    body = reference.active_variant.content_bodies.find_by!(role: "reference")

    text = Conversations::ReferenceSnapshot.summary_entries(body).join("\n")

    assert_includes text, "inspect source"
    assert_includes text, "read_file"
    assert_includes text, "re-read conversation turn #{reference.public_id}"
    assert_not_includes text, "VALUE THAT MUST STAY OUT OF A SUMMARY"
  end

  test "native replay is decided for the side target while phased words and tool order stay frozen" do
    _turn, run = running!("trace question")
    run_loop_round!(run, responses_output([
      { "type" => "reasoning", "id" => "rs_1", "encrypted_content" => "FIRST NATIVE",
        "summary" => [{ "type" => "summary_text", "text" => "a plan" }] },
      { "type" => "message", "id" => "msg_1", "role" => "assistant", "phase" => "commentary",
        "content" => [{ "type" => "output_text", "text" => "Reading now." }] },
      { "type" => "function_call", "id" => "fc_a", "call_id" => "call_a", "name" => "read_file",
        "arguments" => '{"path":"a"}' },
      { "type" => "reasoning", "id" => "rs_2", "encrypted_content" => "SECOND NATIVE",
        "summary" => [{ "type" => "summary_text", "text" => "next step" }] },
      { "type" => "function_call", "id" => "fc_b", "call_id" => "call_b", "name" => "read_file",
        "arguments" => '{"path":"b"}' },
    ]))
    side = fork!
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    replay = Conversations::ContextAssembly::Replay.from_selection(selection)
    assembly = Conversations::ContextAssembly.assemble(conversation: side, prompt: "aside",
      principal: @human, reasoning: replay)
    native = Nexus::InputEntries.for(assembly.messages)
    assert_equal %w[reasoning_item message tool_call_item reasoning_item tool_call_item tool_result_item tool_result_item],
      native.drop(1).first(7).map { |entry| entry.fetch("type", "message") }
    assert_equal "Reading now.", native[2].dig("parts", 0, "text")
    assert_equal "commentary", native[2]["phase"]
    assert_equal "FIRST NATIVE", native[1].dig("payload", "encrypted_content")
    assert_equal "SECOND NATIVE", native[4].dig("payload", "encrypted_content")

    silenced = Conversations::ContextAssembly.assemble(conversation: side, prompt: "aside",
      principal: @human, reasoning: replay.with(mode: "none"))
    assert_equal native.reject { |entry| entry["type"] == "reasoning_item" },
      Nexus::InputEntries.for(silenced.messages)
  end

  test "selected tool deliveries stay readable but only pointers enter the frozen summary" do
    steps = [
      parallel(
        tool("selected_tool", "read_file", "input" => { "path" => "ledger.txt" },
          "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }),
        ask("selected_answer", "prompt" => "Which label?"),
        model("selected_model", "prompt" => "Explain the evidence")
      ),
      model("consumer", "prompt" => "Use the selected work",
        "results" => %w[selected_tool selected_answer selected_model]),
    ]
    _turn, run = running!("read the selected work")
    apply_via(loop_attempt(run), sse_success("starting the work"))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    grow!(run, *steps)
    schedule_loop!(run)
    settled = AgentRuns::Parks::Settle.call(node: loop_node(run, "selected_tool"), trusted: true,
      content: "EXACT TOOL VALUE MUST NOT BE PARAPHRASED", outcome: "completed", is_error: true)
    assert_predicate settled, :applied?, settled.outcome.inspect
    answer = loop_node(run, "selected_answer")
    answered = AgentRuns::Parks::Settle.call(node: answer, claim_token: answer.resolution_token,
      content: "the person's selected label", creator: @human)
    assert_predicate answered, :applied?, answered.outcome.inspect
    run_loop_round!(run, sse_success("the analyst's selected words"))
    assert_equal "running", loop_node(run, "consumer").status
    assert_includes round_request_entries(loop_node(run, "consumer")).to_json,
      "EXACT TOOL VALUE MUST NOT BE PARAPHRASED"

    side = fork!
    reference = side.conversation_turns.sole
    body = reference.active_variant.content_bodies.find_by!(role: "reference")
    before = entries(side)
    summary = Conversations::ReferenceSnapshot.summary_entries(body)
    text = summary.join("\n")

    assert_includes before.to_json, "EXACT TOOL VALUE MUST NOT BE PARAPHRASED"
    assert_includes reference.active_variant.content_bodies.find_by!(role: "content").effective_text,
      "EXACT TOOL VALUE MUST NOT BE PARAPHRASED"
    assert_not_includes text, "EXACT TOOL VALUE MUST NOT BE PARAPHRASED"
    assert_includes text, "Tool read_file (completed, error)"
    assert_includes text, "ledger.txt"
    assert_includes text, "the person's selected label"
    assert_includes text, "the analyst's selected words"
    assert_includes text, "re-read conversation turn #{reference.public_id}"
    assert_includes text, "run status running"
    assert_includes text, "parent keeps its execution"

    run_loop_round!(run, sse_success("later consumer answer"))
    Conversations::Turns::Converge.call
    @account.update!(execution_details_retention_days: 90)
    run.update!(completed_at: 100.days.ago)
    assert_equal 1, Conversations::ExecutionDetails::Prune.call(account: @account, batch: 20)[:pruned]

    assert_empty run.agent_run_tasks.reload
    assert_equal before, entries(side)
    assert_equal summary, Conversations::ReferenceSnapshot.summary_entries(body.reload)
    assert_not_includes summary.join("\n"), "later consumer answer"
  end

  test "a peer sees parent prose and progress without inheriting its private preface or tool work" do
    turn, run = materialize_loop_reply!(@conversation, agent: @human, text: "the shared question",
      context_options: { "inline" => [{ "role" => "developer", "position" => "lead", "text" => "SOURCE PREFACE" }] })
    schedule_loop!(run)
    tools!(run, ["landed"])
    settle!(run, "landed", "SOURCE TOOL VALUE")
    side = fork!
    peer = users(:curator)
    assert_not_equal turn.answering_user, peer

    captured = entries(side, answerer: peer)

    assert_includes captured.to_json, "the shared question"
    assert_includes captured.to_json, "Mock: checking"
    assert_includes captured.to_json, "Parent turn reference snapshot"
    assert_not_includes captured.to_json, "SOURCE PREFACE"
    assert_not_includes captured.to_json, "SOURCE TOOL VALUE"
    assert_not captured.any? { |entry| entry["type"] == "tool_call_item" }
  end

  test "a reference owns image and nonmedia captures after the parent execution is pruned" do
    picture = capture!("progress.png", "image/png", Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    ))
    log = capture!("progress.txt", "text/plain", "the durable log")
    _turn, run = running!("inspect the captures")
    tools!(run, ["capture"])
    node = run.agent_run_tasks.find_by!(tool_call_id: "capture")
    executor = TaskExecutor.address_for(@agent)
    claim = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: run, task_key: node.node_key, executor: executor
    ))
    assert_predicate claim, :accepted?
    commit = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: run, task_key: node.node_key, executor: executor, claim_token: claim.value.claim_token,
      content: [{ "type" => "text", "text" => "captured" }, *[picture, log].map { |upload|
        { "type" => "resource_link", "uri" => "nexus://uploads/#{upload.public_id}", "name" => upload.filename.to_s }
      }], structured_content: nil, result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
    ))
    assert_predicate commit, :applied?
    side = fork!
    body = side.conversation_turns.sole.active_variant.content_bodies.find_by!(role: "reference")
    assert_equal [picture.id, log.id].sort, body.content_uploads.pluck(:id).sort
    before = entries(side)
    assert_includes before.to_json, picture.public_id
    summary = Conversations::ReferenceSnapshot.summary_entries(body).join("\n")
    assert_includes summary, "progress.png"
    assert_includes summary, Conversations::ContextAssembly::AttachmentLine::NOT_CARRIED

    schedule_loop!(run)
    run_loop_round!(run, sse_success("finished"))
    Conversations::Turns::Converge.call
    @account.update!(execution_details_retention_days: 90)
    run.update!(completed_at: 100.days.ago)
    assert_equal 1, Conversations::ExecutionDetails::Prune.call(account: @account, batch: 20)[:pruned]
    assert_empty run.agent_run_tasks.reload
    assert_equal before, entries(side)
    _side_turn, side_run = materialize_loop_reply!(side, agent: @human, text: "read the captured log")
    assert_equal log.id, Executors::Attachments.fetch(agent_run: side_run, public_id: log.public_id).id
    assert_equal picture.id, Executors::Attachments.fetch(agent_run: side_run, public_id: picture.public_id).id

    text_only = Conversations::ContextAssembly::ChatHistory.call(conversation: side,
      before_position: side_run.conversation_turn.position, answerer: @agent,
      carries: ->(_type) { Conversations::ContextAssembly::AttachmentLine::NOT_SHOWN })
    text_entries = Nexus::InputEntries.for(text_only.segments.flat_map(&:elements))
    assert_not text_entries.any? { |entry| Array(entry["parts"]).any? { |part| part["type"] == "upload" } }
    assert_includes text_entries.to_json, "progress.png"
  end

  test "retained work can exceed one request body while the ordinary history fit bounds what is sent" do
    _turn, run = running!("keep both results")
    tools!(run, %w[first second])
    settle!(run, "first", "A" * 600_000)
    settle!(run, "second", "B" * 600_000)

    side = fork!
    reference = side.conversation_turns.sole.active_variant.content_bodies.find_by!(role: "reference")

    # byte_size is the body's readable-text projection, not storage size.
    # The same canonical measure the request seal uses must exceed its wall.
    storage = ContentBodies::Measure.call(reference.entry_payloads)
    assert_operator storage.bytes, :>, Nexus::SizeBounds::BOUNDS.fetch(:snapshot_bound).fetch(:value)
    assert_not_predicate storage, :within_bound?
    assert_equal [600_000, 600_000], entries(side).select { |entry| entry["type"] == "tool_result_item" }
      .map { |entry| entry.dig("payload", "output").bytesize }
    fitted = Conversations::ContextAssembly::ChatHistory.call(conversation: side,
      answerer: @agent, byte_budget: 4096)
    assert_equal "budget_exceeded", fitted.skipped_reason
    assert_not fitted.segments.any? { |segment| segment.call_items.any? }, "a whole call/result round leaves together"
  end

  private

    def running!(text)
      turn, run = materialize_loop_reply!(@conversation, agent: @human, text: text)
      schedule_loop!(run)
      [turn, run]
    end

    def tools!(run, ids)
      run_loop_round!(run, sse_success("checking", tool_calls: ids.map { |id|
        { id: id, name: "read_file", arguments: { path: id }.to_json }
      }))
    end

    def settle!(run, id, text)
      result = AgentRuns::Parks::Settle.call(node: run.agent_run_tasks.find_by!(tool_call_id: id),
        trusted: true, content: text, outcome: "completed")
      assert_predicate result, :applied?
    end

    def capture!(filename, content_type, bytes)
      @account.content_uploads.create!(creating_executor: TaskExecutor.address_for(@agent),
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename,
          content_type: content_type, identify: false))
    end

    def fork!
      result = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: @conversation.reload, turn_public_id: nil, variant_public_id: nil,
        acting_user: @human, title: nil, side: true
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def entries(side, answerer: @agent)
      selection = Conversations::ContextAssembly::ChatHistory.call(conversation: side.reload, answerer: answerer)
      Nexus::InputEntries.for(selection.segments.flat_map(&:elements))
    end
end
