require "test_helper"

# ONE ASSEMBLER. A loop-backed turn's history is rendered from its ROWS — the in-turn summary when
# one arrived, then each spine round through RoundReplay, the pairing law closing a call the round
# never heard back from — and never from the variant's content, which is the presenter's projection.
# And the loop's round one seals the SAME bytes a tool-less direct reply seals: the prompt cache
# keeps earning across engines, and across turns.
class Conversations::ContextAssemblyLoopBackedTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    # Answered by the agent: the engine of every reply head here is the agent's.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def say!(text, conversation: @conversation)
    post_input!(conversation, acting_user: @human, text: text)
  end

  def drain!(conversation = @conversation)
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
  end

  def converge! = Conversations::Turns::Converge.call

  # Character for character — the unit a provider's prefix cache matches.
  def canonical(entries) = entries.map { |payload| Nexus::CanonicalJson.encode(payload) }

  # Each entry rendered to a comparable shape: role and text — a merged
  # message's texts as a list, each part its own, never folded — or the
  # splice item's kind and pairing key.
  def shape(entries)
    entries.map do |payload|
      case payload["type"]
      when "tool_call_item" then ["call", payload.dig("payload", "call_id")]
      when "tool_result_item" then ["result", payload.dig("payload", "call_id"), payload.dig("payload", "output")]
      when "reasoning_item" then ["reasoning"]
      else
        texts = payload.fetch("parts").map { |part| part["text"] }
        [payload["role"], texts.one? ? texts.sole : texts]
      end
    end
  end

  # Each entry as placement sees it: a blob by its bytes, a call or result
  # by its pairing key, a message by its role, words and phase.
  def placed(entries)
    entries.map do |payload|
      case payload["type"]
      when "reasoning_item" then ["reasoning", payload.dig("payload", "encrypted_content")]
      when "tool_call_item" then ["call", payload.dig("payload", "call_id")]
      when "tool_result_item" then ["result", payload.dig("payload", "call_id")]
      else [payload["role"], payload.dig("parts", 0, "text"), payload["phase"]]
      end
    end
  end

  def reply_attempt(conversation)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == conversation.id
    end
    raise "reply not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  def wire_payload(attempt)
    built = build(attempt)
    raise "build refused: #{built.refusal.inspect}" unless built.built?

    JSON.parse(built.request.payload)
  end

  # The NEXT turn's history, read off its round one: on a conversation the agent answers, the
  # person's own reply head is a loop-backed turn too, and its round one is the tool-less reply's
  # request plus the tool block — so the history reads exactly as a plain reply's would.
  def next_turn_entries!(prompt)
    _turn, next_loop = materialize_loop_reply!(@conversation, agent: @human, text: prompt)
    schedule_loop!(next_loop)
    round_request_entries(loop_node(next_loop, "r1"))
  end

  def assembled_text(prompt: "next")
    Conversations::ContextAssembly.assemble(conversation: @conversation.reload, prompt: prompt,
      principal: @human)
      .messages.map { |message| message.parts.map(&:text).join }.join("\n")
  end

  # Admission admits everything queued at once, so a round is found through
  # its own invocation, never by luck.
  def attempt_for(agent_loop, key)
    invocation_id = loop_node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  # The running round answers with one flat-tool call; the kernel's jobs run.
  def call_round!(agent_loop, key, name, arguments)
    apply_via(attempt_for(agent_loop, key), sse_success("delegating", tool_calls: [
      { id: "call_#{name}", name: name, arguments: arguments.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    agent_loop.reload
  end

  def run_round!(agent_loop, key, text)
    apply_via(attempt_for(agent_loop, key), sse_success(text))
    AgentLoops::ConvergeTerminalSteps.call
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    agent_loop.reload
  end

  def envelope(task, status, prompt, text)
    "<task_result task=\"#{task}\" status=\"#{status}\">\n<prompt>#{prompt}</prompt>\n#{text}\n</task_result>"
  end

  def tool_output(node) = node.content_bodies.find_by!(role: "output").effective_text

  # ── The two prefix-stability pins ────────────────────────────────

  test "two loop-backed turns: the second's round one is the first's, byte for byte, then what followed" do
    declare_tools!(@agent)
    say!("materialize me first")
    turn1, loop1 = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(loop1)
    first = canonical(round_request_entries(loop_node(loop1, "r1")))

    run_loop_round!(loop1, sse_success("first answer"))
    assert_equal "completed", loop1.reload.status
    converge!
    assert_equal "completed", turn1.reload.status
    # The projection is not the record: assembly reads rows, never this body.
    ContentBodies::Replace.call(owner: turn1.active_variant, role: "content",
      entries: [{ "text" => "PROJECTION ONLY" }], seal: true)

    say!("and next")
    _turn2, loop2 = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(loop2)
    second_entries = round_request_entries(loop_node(loop2, "r1"))

    assert_equal [["user", "materialize me first"]], shape(round_request_entries(loop_node(loop1, "r1")))
    assert_equal first, canonical(second_entries).first(first.length),
      "turn N+1's prefix is turn N's request, character for character"
    assert_equal [["assistant", "Mock: first answer"], ["user", "and next"]],
      shape(second_entries).drop(first.length),
      "then the round's own answer from its rows, and the new input"
    refute_includes canonical(second_entries).join, "PROJECTION ONLY",
      "a loop-backed variant's content is the presenter's, never the assembler's"
  end

  test "a loop-backed round one is the tool-less reply's request plus the tool block, with no instructions" do
    declare_tools!(@agent)
    lead = { "inline" => [{ "role" => "developer", "position" => "lead", "text" => "You are terse." }] }
    twin = Conversation.create!(workspace: @workspace, creating_user: @human)
    say!("materialize me first")
    say!("materialize me first", conversation: twin)

    post_input!(twin, acting_user: @human, kind: "direct_reply", text: "what is up",
      provider_id: "dev", model_ref: "mock-text", context_options: lead)
    drain!(twin)
    direct = twin.model_invocations.sole
    direct_payload = wire_payload(reply_attempt(twin))

    _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "what is up",
      context_options: lead)
    schedule_loop!(agent_loop)
    r1 = loop_node(agent_loop, "r1")
    assert_nil r1.system_instructions, "round one carries no system field"
    loop_payload = wire_payload(loop_attempt(agent_loop))

    assert_equal canonical(sealed_request_entries(direct)), canonical(round_request_entries(r1)),
      "the same normalized elements, sealed by both engines"
    assert_equal direct_payload.fetch("input").to_json, loop_payload.fetch("input").to_json,
      "identical `input` on the wire - the third prompt-cache pin"
    assert_equal ["read_file"], loop_payload.fetch("tools").map { |tool| tool.fetch("name") }
    # `prompt_cache_key` routes OpenAI's prefix cache by CONVERSATION (F4):
    # the twin's reply and the loop's round carry their own conversations'
    # ids, the one byte that legitimately differs beside the tool block.
    assert_equal twin.public_id, direct_payload.fetch("prompt_cache_key")
    assert_equal @conversation.public_id, loop_payload.fetch("prompt_cache_key")
    assert_equal direct_payload.except("prompt_cache_key"), loop_payload.except("tools", "prompt_cache_key"),
      "the loop's request differs from the direct reply's by the tool block and the routing key alone"
    assert_not loop_payload.key?("instructions"),
      "the per-turn text rides the list, or every round would carry the lead twice"
    assert_equal 1, round_request_entries(r1).count { |payload| payload["role"] == "developer" }
    assert_equal "You are terse.",
      round_request_entries(r1).find { |payload| payload["role"] == "developer" }.dig("parts", 0, "text")
  end

  # The twin with the three slots: the slot blocks are LIST items placed by the one assembler, so
  # the loop-backed round one is still the tool-less reply's request plus the tool block, with no
  # `instructions`, and the one system entry opens with the system_prompt. The direct reply on the
  # twin runs under NO declaring profile (its poster is a Human, its creator a Human), so its
  # `system_prompt` slot rides as an inline slot override carrying the registered text — the one way
  # a profile-less turn carries that slot; the loop-backed turn reads the agent's registered row.
  # Both post as the agent's steward, so the `persona` slot is the same Human's — and the twin is
  # the steward's own conversation, so the steward's words are its own voice there, bare as the
  # agent's are on the other.
  test "a loop-backed round one with three slots is still the tool-less reply's request plus the tool block" do
    declare_tools!(@agent)
    steward = users(:owner)
    system_prompt = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
      content: "I am the agent.").document
    PromptDocuments::Write.call(anchor: { workspace: @workspace }, slot: "character", content: "The room is {{workspace}}.")
    PromptDocuments::Write.call(anchor: { user: steward }, slot: "persona", content: "The person is {{user}}.")
    twin = Conversation.create!(workspace: @workspace, creating_user: steward)
    say!("materialize me first")
    post_input!(twin, acting_user: steward, text: "materialize me first")

    post_input!(twin, acting_user: steward, kind: "direct_reply", text: "what is up",
      provider_id: "dev", model_ref: "mock-text",
      context_options: { "inline" => [{ "slot" => "system_prompt", "text" => system_prompt.content }] })
    drain!(twin)
    direct = twin.model_invocations.sole
    direct_payload = wire_payload(reply_attempt(twin))

    _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "what is up")
    schedule_loop!(agent_loop)
    r1 = loop_node(agent_loop, "r1")
    assert_nil r1.system_instructions, "round one carries no system field — the slots are list items"
    loop_payload = wire_payload(loop_attempt(agent_loop))

    assert_equal canonical(sealed_request_entries(direct)), canonical(round_request_entries(r1)),
      "the same normalized elements, slots included, sealed by both engines"
    # `prompt_cache_key` routes OpenAI's prefix cache by CONVERSATION (F4):
    # the twin's reply and the loop's round carry their own conversations'
    # ids, the one byte that legitimately differs beside the tool block.
    assert_equal twin.public_id, direct_payload.fetch("prompt_cache_key")
    assert_equal @conversation.public_id, loop_payload.fetch("prompt_cache_key")
    assert_equal direct_payload.except("prompt_cache_key"), loop_payload.except("tools", "prompt_cache_key"),
      "the loop's request differs from the direct reply's by the tool block and the routing key alone"
    assert_not loop_payload.key?("instructions")
    systems = round_request_entries(r1).select { |payload| payload["role"] == "system" }
    assert_equal 1, systems.length, "three system slots merge into the list's one leading system entry"
    assert_equal ["I am the agent.", "The room is Shared.", "The person is Owner."],
      systems.sole.fetch("parts").map { |part| part["text"] }, "each slot its own part"
    assert_equal "system", round_request_entries(r1).first["role"], "and it is the first item"
  end

  # ── The summary turn ──

  test "the summary turn renders its content once, in the user role, and no byte of the summarizer's request" do
    say!("turn zero, before the summary")
    post_input!(@conversation, acting_user: @human, kind: "direct_reply", text: "what now",
      provider_id: "dev", model_ref: "mock-text")
    drain!
    apply_via(reply_attempt(@conversation), sse_success("the first answer"))
    converge!

    requested = Conversations::Compaction::Request.call(
      Conversations::Compaction::Request::Command.new(
        conversation: @conversation, acting_user: @human, model: "dev/mock-text"
      )
    )
    assert_predicate requested, :accepted?
    # The summary settles through its one-task loop's own chain: the step
    # the scheduler mints, applied and converged, then the turn.
    summary_loop = requested.value.turn.active_variant.agent_loop
    schedule_loop!(summary_loop)
    run_loop_round!(summary_loop, sse_success("THE SUMMARY"))
    converge!
    assert_equal "completed", requested.value.turn.reload.status

    messages = Conversations::ContextAssembly.assemble(conversation: @conversation.reload, prompt: "next",
      principal: @human).messages
    summaries = messages.select { |message| message.parts.map(&:text).join.include?("Mock: THE SUMMARY") }
    assert_equal 1, summaries.length, "the summary rides once"
    assert_equal "user", summaries.sole.role, "a summary of what a user said is never an instruction"
    text = messages.map { |message| message.parts.map(&:text).join }.join("\n")
    assert_includes text, Conversations::ContextAssembly::ChatHistory::COMPACTION_HEADER
    assert_includes text, Conversations::Compaction::REREAD_RULE,
      "the kernel states the re-read rule under the header; the summariser is never trusted to"
    refute_includes text, "turn zero", "history begins at the summary"
    refute_includes text, "You are compacting", "the summarizer's own request never reaches history"
    refute_includes text, "Mock: the first answer"
  end

  # ── The round's own order ────────────────────────────

  # A round that thought, spoke and thought again between its calls reads
  # back in a later turn exactly as its continuation sent it: each blob
  # before the item it produced, the labelled message at its place. The
  # history lane lands its replay into the round's placement rather than
  # ordering the round a second time; silenced, the blobs go and the label
  # stays.
  test "a later turn replays a round's reasoning and labelled message where the round produced them" do
    declare_tools!(@agent)
    say!("materialize me first")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, responses_output([
      { "type" => "reasoning", "id" => "rs_1", "encrypted_content" => "E1",
        "summary" => [{ "type" => "summary_text", "text" => "plan one" }] },
      { "type" => "message", "id" => "msg_1", "role" => "assistant", "phase" => "commentary",
        "content" => [{ "type" => "output_text", "text" => "Reading both." }] },
      { "type" => "function_call", "id" => "fc_a", "call_id" => "call_a", "name" => "read_file",
        "arguments" => '{"path":"a"}' },
      { "type" => "reasoning", "id" => "rs_2", "encrypted_content" => "E2",
        "summary" => [{ "type" => "summary_text", "text" => "plan two" }] },
      { "type" => "function_call", "id" => "fc_b", "call_id" => "call_b", "name" => "read_file",
        "arguments" => '{"path":"b"}' },
    ]))
    %w[call_a call_b].each do |call_id|
      settled = AgentLoops::Parks::Settle.call(node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: call_id),
        trusted: true, content: "contents of #{call_id}", outcome: "completed")
      assert_predicate settled, :applied?
    end
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("both read"))
    converge!
    assert_equal "completed", turn.reload.status

    round = [["reasoning", "E1"], ["assistant", "Reading both.", "commentary"], ["call", "call_a"],
             ["reasoning", "E2"], ["call", "call_b"], ["result", "call_a"], ["result", "call_b"]]
    assert_equal [["user", "materialize me first", nil], *round, ["assistant", "Mock: both read", nil],
                  ["user", "tell me", nil]],
      placed(next_turn_entries!("tell me")), "the history lane's order is the loop lane's"

    silenced = Conversations::ContextAssembly.assemble(conversation: @conversation.reload, prompt: "next",
      principal: @human, reasoning: Conversations::ContextAssembly::Replay.from_selection(
        DevModelLane.selection(workload: "text_generation", account: @account), mode: "none"
      ))
    assert_equal round.reject { |entry| entry.first == "reasoning" },
      placed(Nexus::InputEntries.for(silenced.messages)).drop(1).first(5),
      "replay silenced: the blobs go, the label and the order stay"
  end

  # A labelled round's words ride their own messages, so its host holds only
  # the fence another model on the lane reads — and the history lane hosts
  # that fence in the bytes the loop lane sent, or every later message's
  # prefix moves.
  test "another model reads nothing of a labelled round's thinking, in history as in the loop's own continuation" do
    declare_tools!(@agent)
    say!("materialize me first")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, responses_output([
      { "type" => "reasoning", "id" => "rs_1", "encrypted_content" => "E1",
        "summary" => [{ "type" => "summary_text", "text" => "plan one" }] },
      { "type" => "message", "id" => "msg_1", "role" => "assistant", "phase" => "commentary",
        "content" => [{ "type" => "output_text", "text" => "Reading it." }] },
      { "type" => "function_call", "id" => "fc_a", "call_id" => "call_a", "name" => "read_file",
        "arguments" => '{"path":"a"}' },
    ]))
    settled = AgentLoops::Parks::Settle.call(node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a"),
      trusted: true, content: "contents of call_a", outcome: "completed")
    assert_predicate settled, :applied?
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("read"))
    converge!
    assert_equal "completed", turn.reload.status

    replay = Conversations::ContextAssembly::Replay.new(mode: "last_turn",
      target: ModelReasoning::ReplayLadder::Target.new(provider_id: "dev", model_id: "another-model",
        reasoning_effort: "medium",
        capability: Nexus::ReasoningReplayCapability.new(format: "responses_reasoning")))
    round = loop_node(agent_loop, "r1")
    host = AgentLoops::RoundReplay.call(round, fan_by_call_id: AgentLoops::RoundReplay.fans_of([round]).fetch(round.id),
      replay: replay).message
    assert_nil host, "a phased round hosts only what the ladder lands, and another model's blob lands nothing"

    history = Nexus::InputEntries.for(Conversations::ContextAssembly.assemble(conversation: @conversation.reload,
      prompt: "next", principal: @human, reasoning: replay).messages)
    assert_equal [["user", "materialize me first", nil], ["assistant", "Reading it.", "commentary"],
                  ["call", "call_a"], ["result", "call_a"]],
      placed(history).first(4)
    assert_not_includes history.to_json, "plan one"
  end

  # ── The dangling call ────────────────────────────────

  test "a hold-settled turn renders from its rows: the call it made, closed by the pairing envelope" do
    declare_tools!(@agent)
    say!("materialize me first")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("calling", tool_calls: [
      { id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" },
    ]))
    assert_equal "dispatched", agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a").status

    AgentLoops::Transition.agent_loop(agent_loop, status: "needs_attention",
      attention_reason: "halt_failure")
    converge!
    assert_equal "failed", turn.reload.status
    assert_nil turn.active_variant.content_bodies.find_by(role: "content"), "a hold copies no answer"

    say!("never mind, do this instead")
    entries = next_turn_entries!("what did it read")
    assert_equal [
      ["user", "materialize me first"],
      ["assistant", "Mock: calling"],
      ["call", "call_a"],
      ["result", "call_a", "#{AgentLoops::RoundReplay::Pairing::ERROR_OPEN}" \
        "#{AgentLoops::RoundReplay::Pairing::UNANSWERED}#{AgentLoops::RoundReplay::Pairing::ERROR_CLOSE}"],
      ["user", ["never mind, do this instead", "what did it read"]],
    ], shape(entries),
      "a failed turn still renders whatever it did; the unanswered call is closed " \
        "with the kernel's envelope, and no error prose enters history"
  end

  # ── The branch tip in a later turn ──

  test "a later turn renders a waited task call as its tip's envelope, never the tool's own started text" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, READ_TOOL])
    say!("materialize me first")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    call_round!(agent_loop, "r1", "task", { prompt: "dig in", wait: true })
    assert_equal "running", loop_node(agent_loop, "r2t0-model-1").status
    assert_equal "Task r2t0 started.\nTask reference: agent_loop=\"#{agent_loop.public_id}\", task=\"r2t0\".", tool_output(loop_node(agent_loop, "r2t0")),
      "the call's own output is the kernel tool's receipt"
    run_round!(agent_loop, "r2t0-model-1", "done: found it")
    run_round!(agent_loop, "r2", "the deliverable")
    assert_equal "completed", agent_loop.status
    converge!
    assert_equal "completed", turn.reload.status

    say!("what did it find")
    entries = next_turn_entries!("tell me")
    assert_equal [
      ["user", "materialize me first"],
      ["assistant", "Mock: delegating"],
      ["call", "call_task"],
      ["result", "call_task", envelope("r2t0", "completed", "dig in", "Mock: done: found it")],
      ["assistant", "Mock: the deliverable"],
      ["user", ["what did it find", "tell me"]],
    ], shape(entries),
      "the branch's last word IS the call's result, in a later turn as in the continuation's own request"
    refute_includes canonical(entries).join, "Task r2t0 started."
  end

  test "a mailed background tip renders once: the call keeps its own output, the mail is the delivery" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, READ_TOOL])
    say!("run the suite while I keep working")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    call_round!(agent_loop, "r1", "task", { prompt: "long test run" })
    run_round!(agent_loop, "r2", "meanwhile")
    assert_predicate agent_loop, :delivered?
    converge!
    assert_equal "completed", turn.reload.status
    run_round!(agent_loop, "r2t0-model-1", "all green")
    assert_equal "completed", agent_loop.status
    AgentLoops::MailJob.perform_now(agent_loop.id)
    assert_not_nil loop_node(agent_loop, "r2t0-model-1").reload.mailed_at
    # The receipt WAKES the conversation: the woken round's request is the whole timeline with the
    # envelope as its trailing user message — the mail's segment is the delivery; the call answers
    # with what the model read at the time.
    assert_equal 1, drain!, "the receipt is a turn of its own"
    woken = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    schedule_loop!(woken)

    started = tool_output(loop_node(agent_loop, "r2t0"))
    assert_match(/\ATask r2t0 started in the background\./, started)
    delivery = envelope("r2t0", "completed", "long test run", "Mock: all green")
    entries = round_request_entries(loop_node(woken, "r1"))
    assert_equal [
      ["user", "run the suite while I keep working"],
      ["assistant", "Mock: delegating"],
      ["call", "call_task"],
      ["result", "call_task", started],
      ["assistant", "Mock: meanwhile"],
      ["user", delivery],
    ], shape(entries)
    # The receipt names the envelope that will come; only the envelope
    # itself carries a status.
    assert_equal 1, canonical(entries).join.scan("<task_result task=\\\"r2t0\\\" status=").length,
      "one delivery per result"

    # After the woken turn, a later turn's history renders the woken turn as the words that opened
    # it — the envelope, its SEED, in the user role — then its answer: the delivery is in history
    # exactly once, there and never at the call, whose mailed tip keeps rendering the call's own
    # `started` text.
    run_round!(woken, "r1", "noted")
    converge!
    say!("what did it find?")
    entries = next_turn_entries!("tell me")
    assert_equal [
      ["assistant", "Mock: meanwhile"],
      ["user", delivery],
      ["assistant", "Mock: noted"],
      ["user", ["what did it find?", "tell me"]],
    ], shape(entries).last(4)
    assert_includes shape(entries), ["result", "call_task", started], "the call keeps its own output"
    assert_equal 1, canonical(entries).join.scan("<task_result task=\\\"r2t0\\\" status=").length,
      "delivered once: the woken turn's seed, never the call"
  end

  # ── The seed: a reply turn's own words are the next turn's history ──

  # The rho shape: every person turn is a `direct_reply` whose text is the
  # person's words, and no `message` turn is ever posted. Before 1b a
  # later turn saw what the person asked only through the model's answer.
  test "a person's reply words are the next turn's history, and the prefix is the whole earlier request" do
    declare_tools!(@agent)
    turn1, loop1 = materialize_loop_reply!(@conversation, agent: @agent, text: "read the notes")
    schedule_loop!(loop1)
    first = canonical(round_request_entries(loop_node(loop1, "r1")))
    run_loop_round!(loop1, sse_success("the notes, read"))
    converge!
    assert_equal "completed", turn1.reload.status
    assert_equal "read the notes",
      turn1.active_variant.content_bodies.find_by!(role: "prompt").readable_text,
      "the input's body lives on as the variant's prompt"

    _turn2, loop2 = materialize_loop_reply!(@conversation, agent: @agent, text: "and the rest")
    schedule_loop!(loop2)
    second = round_request_entries(loop_node(loop2, "r1"))

    assert_equal [
      ["user", "read the notes"],
      ["assistant", "Mock: the notes, read"],
      ["user", "and the rest"],
    ], shape(second), "the question, in the user role, then the answer, then the new question"
    assert_equal first, canonical(second).first(first.length),
      "turn N+1's prefix is turn N's WHOLE request, its trailing user message included"
  end

  test "the seed rides the replay ladder as nothing: user-side material, never a trace item" do
    post_input!(@conversation, acting_user: @human, kind: "direct_reply", text: "first ask",
      provider_id: "dev", model_ref: "mock-text")
    drain!
    apply_via(reply_attempt(@conversation),
      sse_success("one", reasoning: "planned it", reasoning_encrypted: "gAAA-blob"))
    converge!

    post_input!(@conversation, acting_user: @human, kind: "direct_reply", text: "second ask",
      provider_id: "dev", model_ref: "mock-text")
    drain!

    entries = sealed_request_entries(@conversation.model_invocations.order(:id).last)
    assert_equal [["user", "first ask"], ["reasoning"], ["assistant", "Mock: one"], ["user", "second ask"]],
      shape(entries), "the seed leads, the replayed item precedes the message it produced"
    seed = entries.first
    assert_nil seed["type"], "no reasoning payload rides the seed"
    assert_equal "gAAA-blob", entries[1].dig("payload", "encrypted_content")
  end

  # The summary stands in for everything the repaired round read — the turn's preface and its seed
  # included — so a later turn renders neither ahead of it.
  test "a summary that led the turn hides its preface and its seed" do
    declare_tools!(@agent, compaction_policy: { "mode" => "kernel" })
    say!("materialize me first")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "start here",
      context_options: { "inline" => [{ "role" => "developer", "position" => "lead", "text" => "env block" }] })
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("calling", tool_calls: [
      { id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" },
    ]))
    r2 = agent_loop.agent_loop_nodes.where(continuation_source: "round").order(:id).last
    repaired = Conversations::Compaction::Arm.call(
      agent_loop: agent_loop, node: r2,
      trigger: Conversations::Compaction::Trigger.manual(user: @human)
    )
    assert repaired, "the repair arms on the continuation"
    AgentLoops::Parks::Settle.call(
      node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a"), trusted: true,
      content: "contents of a", outcome: "completed"
    )
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("the summary"))
    run_loop_round!(agent_loop, sse_success("the final word"))
    assert_equal "completed", agent_loop.reload.status
    converge!
    assert_equal "completed", turn.reload.status

    say!("and then")
    entries = next_turn_entries!("go on")
    assert_equal [
      ["user", ["materialize me first", "#{Conversations::Compaction::REREAD_RULE}\n\nMock: the summary"]],
      ["call", "call_a"],
      ["result", "call_a", "contents of a"],
      ["assistant", "Mock: the final word"],
      ["user", ["and then", "go on"]],
    ], shape(entries), "the summary stands in for everything the repaired round read, the seed included"
    refute_includes canonical(entries).join, "start here"
    refute_includes canonical(entries).join, "env block", "and the preface the seed rode behind"
  end

  # (f-iii): a waited call's result is the call's paired result, and a
  # later turn carries it there exactly once — no seed carries it twice.
  test "a waited task result is in a later turn's history exactly once, at the call" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, READ_TOOL])
    say!("materialize me first")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    call_round!(agent_loop, "r1", "task", { prompt: "dig in", wait: true })
    run_round!(agent_loop, "r2t0-model-1", "done: found it")
    run_round!(agent_loop, "r2", "the deliverable")
    converge!
    assert_equal "completed", turn.reload.status

    turn2, loop2 = materialize_loop_reply!(@conversation, agent: @agent, text: "what did it find")
    schedule_loop!(loop2)
    run_loop_round!(loop2, sse_success("it found it"))
    converge!
    assert_equal "completed", turn2.reload.status
    entries = next_turn_entries!("tell me again")
    assert_includes shape(entries),
      ["result", "call_task", envelope("r2t0", "completed", "dig in", "Mock: done: found it")]
    assert_equal 1, canonical(entries).join.scan("<task_result task=\\\"r2t0\\\" status=").length,
      "the paired result, and no mail: once"
    assert_equal [["user", "what did it find"], ["assistant", "Mock: it found it"], ["user", "tell me again"]],
      shape(entries).last(3)
  end

  # ── The in-turn summary mark ────────────────────────────────

  test "a repaired round renders the summary it read, then only the rounds after it" do
    declare_tools!(@agent, compaction_policy: { "mode" => "kernel" })
    say!("materialize me first")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("calling", tool_calls: [
      { id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" },
    ]))
    r2 = agent_loop.agent_loop_nodes.where(continuation_source: "round").order(:id).last
    assert_not_equal "r1", r2.node_key

    repaired = Conversations::Compaction::Arm.call(
      agent_loop: agent_loop, node: r2,
      trigger: Conversations::Compaction::Trigger.manual(user: @human)
    )
    assert repaired, "the repair arms on the continuation"
    summary_key = repaired.summary_task_key
    AgentLoops::Parks::Settle.call(
      node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a"), trusted: true,
      content: "contents of a", outcome: "completed"
    )
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("the summary"))
    assert_equal "completed", loop_node(agent_loop, summary_key).status
    repaired = round_request_entries(r2.reload).map { |payload| payload.dig("parts", 0, "text") }
    assert_equal "#{Conversations::Compaction::REREAD_RULE}\n\nMock: the summary",
      repaired.find { |text| text.to_s.include?("Mock: the summary") },
      "the repaired round reads the kernel's rule before the summary it replaces history with"
    run_loop_round!(agent_loop, sse_success("the final word"))
    assert_equal "completed", agent_loop.reload.status
    converge!
    assert_equal "completed", turn.reload.status

    say!("and then")
    entries = next_turn_entries!("go on")
    assert_equal [
      ["user", ["materialize me first", "#{Conversations::Compaction::REREAD_RULE}\n\nMock: the summary"]],
      ["call", "call_a"],
      ["result", "call_a", "contents of a"],
      ["assistant", "Mock: the final word"],
      ["user", ["and then", "go on"]],
    ], shape(entries),
      "the summary stands in for the rounds it replaced, and the repaired round follows it"
    refute_includes canonical(entries).join, "Mock: calling"
  end

  # ── The rendering is by the turn's kind, not its source ─────────────────

  test "a loop-backed turn's rounds ride the history budget and count as its entries" do
    declare_tools!(@agent)
    say!("materialize me first")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "the question")
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("calling", tool_calls: [
      { id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" },
    ]))
    AgentLoops::Parks::Settle.call(
      node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a"), trusted: true,
      content: "x" * 4_000, outcome: "completed"
    )
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("done"))
    converge!
    assert_equal "completed", turn.reload.status

    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    unbounded = Conversations::ContextAssembly::ChatHistory.call(conversation: @conversation.reload)
    assert_equal 4, unbounded.selected_count, "the message, the seed, then one segment per round"
    assert_equal %w[user user assistant assistant], unbounded.segments.map(&:role)
    assert_equal "the question", unbounded.segments[1].text
    starved = Conversations::ContextAssembly::ChatHistory.call(
      conversation: @conversation, token_budget: 400, profile: selection.execution_profile
    )
    assert_equal 1, starved.selected_count,
      "a round is priced with its tool results, or a tool-heavy turn is under-funded"
    assert_equal "budget_exceeded", starved.skipped_reason
    refute_includes starved.segments.map(&:text), "the question",
      "a turn's seed is older than its rounds: under a tight budget the rounds outlive the question"
  end

  # ── A round's delivered material in later history ────────────

  # The loop lane sends each delivered tip as its own user message; history renders them the same
  # way — never merged into one message of several parts, never folded — so on every wire (one item
  # per message on Responses and chat, one merged message on Anthropic) the next turn opens with the
  # wake round's request whole.
  test "a round that read two deliveries renders in history as it was sent: each its own message" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, READ_TOOL])
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "work in parallel")
    schedule_loop!(agent_loop)
    apply_via(attempt_for(agent_loop, "r1"), sse_success("delegating", tool_calls: [
      { id: "call_first", name: "task", arguments: { prompt: "first", wait: false, lifetime: "turn" }.to_json },
      { id: "call_second", name: "task", arguments: { prompt: "second", wait: false, lifetime: "turn" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    run_round!(agent_loop, "r2t0-model-1", "first result")
    run_round!(agent_loop, "r2t1-model-1", "second result")
    run_round!(agent_loop, "r2", "foreground result")
    wake = loop_node(agent_loop, "w1")
    read = round_request_entries(wake)
    deliveries = [envelope("r2t0", "completed", "first", "Mock: first result"),
                  envelope("r2t1", "completed", "second", "Mock: second result")]
    assert_equal deliveries.map { |text| ["user", text] }, shape(read).last(2),
      "the loop lane sends each delivered tip as its own user message"
    run_round!(agent_loop, "w1", "synthesized both")
    converge!
    assert_equal "completed", turn.reload.status

    answer = [{ "role" => "assistant", "parts" => [{ "type" => "text", "text" => "Mock: synthesized both" }] }]
    entries = next_turn_entries!("continue")
    assert_equal deliveries.map { |text| ["user", text] },
      shape(entries).select { |role, text| role == "user" && deliveries.include?(text) },
      "each delivery its own message in history, as the loop lane sent it"
    assert_equal canonical(read + answer), canonical(entries).first(read.length + 1),
      "the next turn opens with the wake round's request and answer, entry for entry"
  end
end
