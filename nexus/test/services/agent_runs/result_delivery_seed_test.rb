require "test_helper"

class AgentRuns::ResultDeliverySeedTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK])
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "recovering an unprepared receipt refuses implicit history loss and can retry on a larger model" do
    8.times do |index|
      post_input!(@conversation, acting_user: @human,
        text: "history-marker-#{index} #{SecureRandom.hex(2_000)}")
    end
    assert_equal 8, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    source = deliver_background_result
    source_executions = source.agent_run_tasks.order(:id).pluck(:id, :status, :execution_generation)
    source_invocations = source.model_invocations.order(:id).pluck(:id)
    receipt = @conversation.conversation_inputs.sole.text
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.put_entry("dev/mock-windowless", { "op" => "remove" })
    policy.save!

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turn = @conversation.conversation_turns.order(:position).last
    mail_loop = turn.active_variant.agent_run
    schedule_loop!(mail_loop)
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", mail_loop.reload.status
    node = loop_node(mail_loop, "r1")
    assert_nil node.input_body
    prompt = turn.active_variant.content_bodies.find_by!(role: "prompt")
    assert_equal receipt, prompt.effective_text

    retry_on(mail_loop, "dev/mock-text")
    schedule_loop!(mail_loop)
    assert_equal "needs_attention", mail_loop.reload.status,
      "an implicit fit must not send a silently shortened history"
    assert_equal "history_exceeds_fit", node.reload.error_key
    assert_nil node.input_body
    assert_empty mail_loop.model_invocations
    assert_equal receipt, prompt.reload.effective_text

    policy.delete_entry("dev/mock-windowless")
    policy.save!
    retry_on(mail_loop, "dev/mock-windowless")
    schedule_loop!(mail_loop)
    assert_equal "running", node.reload.status
    assert_predicate node.input_body, :sealed?
    assert_includes node.input_body.effective_text, "history-marker-0"
    assert_includes node.input_body.effective_text, "history-marker-7"
    assert_includes node.input_body.effective_text, "background result"
    finish(mail_loop, "r1", "received with the complete history")
    assert_equal "completed", turn.reload.status
    assert_equal receipt, prompt.reload.effective_text
    assert_equal source_executions, source.agent_run_tasks.order(:id).pluck(:id, :status, :execution_generation)
    assert_equal source_invocations, source.model_invocations.order(:id).pluck(:id)
  end

  # A receipt compiled LATE — no model served it at the drain, so its loop holds the turn and a
  # person's retry names one — cannot arm a summary. The candidate window's end is no hold for it:
  # receipts are small turns, so a busy conversation passes that end long before its window, and no
  # retry changes the count, so a hold there would fail every retry. It sends the newest window;
  # the next drain meets the same end and arms the summary.
  test "a receipt compiled late past the candidate window sends rather than holding" do
    post_input!(@conversation, acting_user: @human, text: "seed")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    deliver_background_result
    mass_history!(Conversations::ContextAssembly::ChatHistory::CANDIDATE_LIMIT)
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.put_entry("dev/mock-windowless", { "op" => "remove" })
    policy.save!
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    mail_loop = @conversation.conversation_turns.order(:position).last.active_variant.agent_run
    schedule_loop!(mail_loop)
    assert_equal "needs_attention", mail_loop.reload.status

    retry_on(mail_loop, "dev/mock-text")
    schedule_loop!(mail_loop)

    node = loop_node(mail_loop, "r1")
    assert_equal "running", node.reload.status, node.error_key.inspect
    assert_predicate node.input_body, :sealed?
    assert_equal ["candidate_limit"], @conversation.conversation_event_items.where(item_type: "context_trimmed")
      .map { |item| item.payload["history_skipped_reason"] }, "the newest window sends, narrated as the trim it is"
  end

  # The kernel's receipt and a person's turn share ONE replay default: on a
  # keep-all lane the woken turn replays every round's thinking the mailing
  # turn carried, as its last request did — never only the last round's.
  test "a receipt on a keep-all lane replays every trace the mailing turn carried" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8192)) do
      _turn, source = materialize_loop_reply!(@conversation, agent: @agent,
        text: "check in the background", model_ref: DevModelLane::WINDOWED_TEXT_MODEL.split("/", 2).last)
      schedule_loop!(source)
      call = { id: "background", name: "delegate_task", arguments: { prompt: "background answer" }.to_json }
      apply_via(attempt_for(source, "r1"),
        sse_success("working", reasoning: "plan", reasoning_encrypted: "blob-a", tool_calls: [call]))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) { schedule_loop!(source) }
      apply_via(attempt_for(source, "r2"),
        sse_success("main answer", reasoning: "check", reasoning_encrypted: "blob-b"))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(source)
      Conversations::Turns::Converge.call
      finish(source, "r2t0-model-1", "background result")
      assert_equal [:delivered], AgentRuns::ResultDelivery.call(source.reload)

      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      mail_loop = @conversation.conversation_turns.order(:position).last.active_variant.agent_run
      schedule_loop!(mail_loop)
      entries = round_request_entries(loop_node(mail_loop, "r1"))
      assert_equal %w[blob-a blob-b],
        entries.filter_map { |payload| payload.dig("payload", "encrypted_content") if payload["type"] == "reasoning_item" }
    end
  end

  # A receipt compiled LATE — its model unresolved at the drain, so ResultDeliverySeed assembles its seed on
  # the first selection that resolves — seals the preface that compile laid, as the drain seals a
  # person's: the template's post-history inline, as rendered. The next turn then opens with the
  # receipt loop's request whole, the inline at its place.
  test "a receipt compiled late seals its preface, and the next turn extends the receipt's request" do
    inline = "Answer in one line."
    declared = Users::DeclareConfiguration.call(user: @agent, tool_definitions: [Nexus::Tools::DELEGATE_TASK],
      approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "assembly", compaction_policy: nil,
      prompt_template: { "blocks" => [
        { "type" => "slot", "slot" => "system_prompt" }, { "type" => "history" },
        { "type" => "inline", "role" => "developer", "text" => inline }, { "type" => "input" },
      ] })
    assert_equal :declared, declared.outcome
    deliver_background_result
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.put_entry("dev/mock-windowless", { "op" => "remove" })
    policy.save!

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turn = @conversation.conversation_turns.order(:position).last
    mail_loop = turn.active_variant.agent_run
    schedule_loop!(mail_loop)
    assert_nil loop_node(mail_loop, "r1").input_body, "nothing compiled while no model resolved"
    assert_nil turn.active_variant.content_bodies.find_by(role: "preface")

    retry_on(mail_loop, "dev/mock-text")
    schedule_loop!(mail_loop)
    assert_equal [{ "role" => "developer", "parts" => [{ "type" => "text", "text" => inline }], "block" => "inline:2" }],
      turn.active_variant.content_bodies.find_by!(role: "preface").entry_payloads,
      "the late compile sealed what it laid between history and the receipt"
    receipt_request = round_request_entries(loop_node(mail_loop, "r1"))
    finish(mail_loop, "r1", "received")
    assert_equal "completed", turn.reload.status

    _next_turn, next_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "and next")
    schedule_loop!(next_loop)
    next_request = round_request_entries(loop_node(next_loop, "r1"))
    answer = { "role" => "assistant", "parts" => [{ "type" => "text", "text" => "Mock: received" }] }
    canonical = ->(entries) { entries.map { |payload| Nexus::CanonicalJson.encode(payload) } }
    assert_equal canonical.(receipt_request + [answer]), canonical.(next_request).first(receipt_request.length + 1),
      "the next turn opens with the receipt's request whole, its inline at its place, then its answer"
    assert_equal [["developer", inline], ["user", "and next"]],
      next_request.last(2).map { |payload| [payload["role"], payload.dig("parts", 0, "text")] }
  end

  test "late receipt preparation keeps the source execution memory binding after configuration changes" do
    @conversation.update!(memory_context: { "bindings" => [] })
    source = deliver_background_result
    @conversation.reload.update!(memory_context: nil)
    written = Conversations::Memory::Apply.write(conversation: @conversation, by: @agent,
      path: "user/new-root.md", content: "must-not-enter-the-frozen-receipt", expected: nil)
    assert_predicate written, :accepted?
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.put_entry("dev/mock-windowless", { "op" => "remove" })
    policy.save!

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    loop = @conversation.conversation_turns.order(:position).last.active_variant.agent_run
    assert_equal source.memory_context, loop.memory_context
    schedule_loop!(loop)
    assert_nil loop_node(loop, "r1").input_body
    retry_on(loop, "dev/mock-text")
    schedule_loop!(loop)
    node = loop_node(loop, "r1")
    assert_predicate node.input_body, :sealed?
    refute_includes node.input_body.effective_text, "must-not-enter-the-frozen-receipt"
  end

  private

    # `count` more completed person messages at the head, mass-inserted rows sharing the first
    # turn's fragment — the candidate window counts turns, not their size.
    def mass_history!(count)
      seed = @conversation.conversation_turns.find_by!(position: 0)
      entry = seed.active_variant.content_bodies.sole.content_body_entries.sole
      head = @conversation.reload.timeline_position_head
      now = Time.current
      turn_ids = ConversationTurn.insert_all!((head...head + count).map do |position|
        { account_id: @account.id, conversation_id: @conversation.id, position: position, kind: "message",
          role: "user", status: "completed", speaker_id: seed.speaker_id,
          control_owner_user_id: @human.id, answering_user_id: @agent.id, visibility: "visible",
          created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      variants = ConversationTurnVariant.insert_all!(turn_ids.map do |turn_id|
        { account_id: @account.id, conversation_turn_id: turn_id, position: 0, status: "completed",
          source: "manual", created_at: now, updated_at: now }
      end, returning: %w[id conversation_turn_id]).rows
      variants.each { |variant_id, turn_id| ConversationTurn.where(id: turn_id).update_all(active_variant_id: variant_id) }
      body_ids = ContentBody.insert_all!(variants.map do |variant_id, _|
        { account_id: @account.id, conversation_turn_variant_id: variant_id, role: "content", sealed_at: now,
          created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      ContentBodyEntry.insert_all!(body_ids.map do |body_id|
        { account_id: @account.id, content_body_id: body_id, content_fragment_id: entry.content_fragment_id,
          position: entry.position, created_at: now, updated_at: now }
      end)
      @conversation.update!(timeline_position_head: head + count)
    end

    def deliver_background_result
      _turn, source = materialize_loop_reply!(@conversation, agent: @agent,
        text: "check in the background", model_ref: "mock-windowless")
      schedule_loop!(source)
      call = { id: "background", name: "delegate_task", arguments: { prompt: "background answer" }.to_json }
      apply_via(attempt_for(source, "r1"), sse_success("working", tool_calls: [call]))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) { schedule_loop!(source) }
      finish(source, "r2", "main answer")
      finish(source, "r2t0-model-1", "background result")
      assert_equal [:delivered], AgentRuns::ResultDelivery.call(source.reload)
      source
    end

    def attempt_for(agent_run, key)
      node = loop_node(agent_run, key)
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: node.selected_model_invocation_id).order(:id).last
    end

    def finish(agent_run, key, text)
      apply_via(attempt_for(agent_run, key), sse_success(text))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
      Conversations::Turns::Converge.call
    end

    def retry_on(agent_run, model)
      result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
        agent_run: agent_run, task_key: "r1", acting_user: @human, model: { "model" => model }
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
    end
end
