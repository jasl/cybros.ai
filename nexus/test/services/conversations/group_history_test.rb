require "test_helper"

# THE RENDERER'S GROUP RULES: the ONE speaker envelope judges every user-side row against the turn
# it assembles for — the input's ADDRESSEE on the wire, the assembling turn's answerer in history —
# and renders ANOTHER agent's reply turn as ONE wrapped user-side segment of its final text (its
# adopted `content`), preceded by its seed under the seed's own voice: never that agent's rounds (a
# wire pairs calls with results of ONE loop). Two seeds are skipped: one the assembling answerer
# itself spoke (its `send` is already the call in its own rounds — a user-role message claiming to
# be the model is bench-sensitive) and a kernel-origin one (that receipt was the other agent's).
# SELF-SEE: an agent reading a conversation where IT answered a turn sees that reply as assistant
# history. Every 1:1 fixture stays byte-stable: the rule bites only when a turn's answerer differs
# from the assembling one.
class Conversations::GroupHistoryTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper
  include AgentMembershipTestHelper

  Envelope = Conversations::ContextAssembly::SpeakerEnvelope

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @steward = users(:owner)
    @curator = users(:curator)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    # B answers to ANOTHER Human than A does, so the two bare sets differ.
    @peer = create_agent_member(display_name: "Peer", steward: @curator)
    @conversation.conversation_access_entries.create!(user: @peer, level: "full")
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, READ_TOOL])
    declare_tools!(@peer, tools: [Nexus::Tools::TASK, READ_TOOL])
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
  def converge! = Conversations::Turns::Converge.call
  def wrapped(author, text) = Envelope.render(author: author, text: text)

  # A merged message's texts as a list, each part its own: the wire merges, nothing folds.
  def shape(entries)
    entries.map do |payload|
      case payload["type"]
      when "tool_call_item" then ["call", payload.dig("payload", "call_id")]
      when "tool_result_item" then ["result", payload.dig("payload", "call_id")]
      else
        texts = payload.fetch("parts").map { |part| part["text"] }
        [payload["role"], texts.one? ? texts.sole : texts]
      end
    end
  end

  def attempt_for(agent_loop, key)
    invocation_id = loop_node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def run_round!(agent_loop, key, text)
    apply_via(attempt_for(agent_loop, key), sse_success(text))
    AgentLoops::ConvergeTerminalSteps.call
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    agent_loop.reload
  end

  def call_round!(agent_loop, key, name, *arguments)
    tool_calls = arguments.each_with_index.map do |fields, index|
      { id: "call_#{name}_#{index}", name: name, arguments: fields.to_json }
    end
    apply_via(attempt_for(agent_loop, key), sse_success("delegating", tool_calls: tool_calls))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    agent_loop.reload
  end

  # A reply head by `by`, addressed `to` (the door's `to:`), drained into
  # its loop-backed turn with round one on the wire.
  def open!(text, by: @human, to: nil)
    post_input!(@conversation, acting_user: by, kind: "direct_reply", text: text,
      provider_id: "dev", model_ref: "mock-text",
      answering_user_public_id: (to && "@#{to.handle}"))
    drain!
    turn = @conversation.conversation_turns.order(:position).last
    agent_loop = turn.active_variant.agent_loop
    schedule_loop!(agent_loop)
    [turn, agent_loop]
  end

  def request_of(agent_loop, key = "r1") = round_request_entries(loop_node(agent_loop, key))

  # A's turn answered, then B's turn — opened by A's own addressed row —
  # answered with one branch in between.
  def two_turns!
    turn_a, loop_a = open!("go")
    run_round!(loop_a, "r1", "A answers")
    converge!
    assert_equal "completed", turn_a.reload.status
    turn_b, loop_b = open!("B, check the indexes", by: @agent, to: @peer)
    assert_equal [@peer, @agent], [turn_b.answering_user, turn_b.speaker_actor.user]
    request_b = request_of(loop_b)
    call_round!(loop_b, "r1", "task", { prompt: "count the indexes" })
    run_round!(loop_b, "r2", "checked")
    converge!
    run_round!(loop_b, "r2t0-model-1", "three")
    assert_equal "completed", turn_b.reload.status
    [turn_a, turn_b, request_b]
  end

  test "another agent's reply is ONE wrapped user-side segment of its final text; the person's words stay bare" do
    _turn_a, _turn_b, request_b = two_turns!

    assert_equal [["user", ["go", wrapped(@agent, "Mock: A answers"), wrapped(@agent, "B, check the indexes")]]],
      shape(request_b).reject { |role, _| role == "system" },
      "for B: the person's word bare (the creator), A's reply as a message from A, and A's addressed row — " \
        "A is not B's person — wrapped as the trailing prompt; one merged user entry"
    assert_empty shape(request_b).select { |role, _| %w[assistant call result].include?(role) },
      "never A's rounds: its calls and results are A's working"
  end

  test "self-see: the answerer reads its own reply as assistant history and skips the seed it spoke itself" do
    _turn_a, _turn_b, = two_turns!
    turn_a2, loop_a2 = open!("and?")
    assert_equal @agent, turn_a2.answering_user

    assert_equal [["user", "go"], ["assistant", "Mock: A answers"],
                  ["user", [wrapped(@peer, "Mock: checked"), "and?"]]],
      shape(request_of(loop_a2)).reject { |role, _| role == "system" },
      "for A: its own turn as rounds; B's turn without the seed A itself sent (already A's call), B's " \
        "answer as one message from B; then the person's next word bare"
    assert_empty shape(request_of(loop_a2)).select { |role, _| %w[call result].include?(role) },
      "B's branch never rides A's wire"

    run_round!(loop_a2, "r1", "A again")
    converge!
    _turn_b2, loop_b2 = open!("B, more?", to: @peer)

    assert_equal [["user", ["go", wrapped(@agent, "Mock: A answers"), wrapped(@agent, "B, check the indexes")]],
                  ["assistant", "Mock: delegating"], ["assistant", "Mock: checked"],
                  ["user", ["and?", wrapped(@agent, "Mock: A again"), "B, more?"]]],
      shape(request_of(loop_b2)).reject { |role, _| role == "system" }.reject { |role, _| %w[call result].include?(role) },
      "for B: its own turn as its two rounds (its seed wrapped — A spoke it), A's turns each as one message " \
        "from A, the person's words bare on both sides"
    assert_equal ["call_task_0", "call_task_0"],
      shape(request_of(loop_b2)).select { |role, _| %w[call result].include?(role) }.map(&:last),
      "B's own branch pairs on B's wire, as before"
  end

  test "a kernel-origin seed of another agent's turn is skipped: the receipt was that agent's" do
    turn_a, loop_a = open!("run it")
    call_round!(loop_a, "r1", "task", { prompt: "count" })
    run_round!(loop_a, "r2", "meanwhile")
    converge!
    assert_equal "completed", turn_a.reload.status
    run_round!(loop_a, "r2t0-model-1", "three")
    AgentLoops::MailJob.perform_now(loop_a.id)
    assert_equal 1, drain!, "the receipt wakes A's turn"
    woken, woken_loop = @conversation.conversation_turns.order(:position).last.then { |t| [t, t.active_variant.agent_loop] }
    assert_equal ["task_result", @agent], [woken.origin, woken.answering_user]
    schedule_loop!(woken_loop)
    run_round!(woken_loop, "r1", "it found three")
    converge!

    _turn_b, loop_b = open!("B?", to: @peer)
    texts = shape(request_of(loop_b)).map(&:last).join("\n")
    assert_not_includes texts, "<task_result", "A's mail is A's: no seed"
    assert_includes texts, wrapped(@agent, "Mock: it found three"), "the woken turn's answer, as a message from A"
    assert_includes texts, wrapped(@agent, "Mock: meanwhile"), "and the turn that started the task"
  end

  test "a turn that produced no text renders only its seed for another agent" do
    turn_a, loop_a = open!("go")
    assert_predicate Conversations::Turns::Cancel.stop_now(@conversation), :accepted?
    AgentLoops::ConvergeTerminalSteps.call
    AgentLoops::EvaluateQuiescence.call(loop_a.reload)
    converge!
    assert_equal "canceled", turn_a.reload.status

    _turn_b, loop_b = open!("B?", to: @peer)
    texts = shape(request_of(loop_b)).map(&:last).join("\n")
    assert_includes texts, "go", "the question A was asked"
    assert_not_includes texts, "<message from=\"@#{@agent.handle}\"", "nothing to wrap"
  end

  # THE BARE DECISION FOLLOWS THE ADDRESSEE: the unlabelled voice of B's turn is B's person, not
  # A's.
  test "on the wire a row is bare for its ADDRESSEE's own voices: the creator, the addressee, its Human" do
    ask = ->(by) do
      post_input!(@conversation, acting_user: by, kind: "direct_reply", text: "words",
        provider_id: "dev", model_ref: "mock-text", answering_user_public_id: "@#{@peer.handle}")
    end

    assert_equal "words", Envelope.for_input(ask.call(@human)), "the creator"
    assert_equal "words", Envelope.for_input(ask.call(@curator)), "B's steward — bare for B, wrapped for A"
    assert_equal wrapped(@steward, "words"), Envelope.for_input(ask.call(@steward)),
      "A's steward is not B's person: wrapped for B (bare on A's own turns, as every 1:1 fixture pins)"
    assert_equal wrapped(@agent, "words"), Envelope.for_input(ask.call(@agent)), "A itself, addressing B"
  end

  # THE PREFACE IS THE ANSWERER'S OWN: B's turn carried a developer lead — B's per-turn text, its
  # environment — which B's own later history replays in place; for A that turn is B's message,
  # its seed and its answer, never B's lead (on a Responses lane it would ride as a developer
  # instruction in A's context).
  test "a peer's reply turn renders its seed and text, never its preface" do
    lead = "B's environment: /srv/b."
    post_input!(@conversation, acting_user: @human, kind: "direct_reply", text: "B, check the indexes",
      provider_id: "dev", model_ref: "mock-text", answering_user_public_id: "@#{@peer.handle}",
      context_options: { "inline" => [{ "role" => "developer", "position" => "lead", "text" => lead }] })
    drain!
    turn_b = @conversation.conversation_turns.order(:position).last
    assert_equal @peer, turn_b.answering_user
    loop_b = turn_b.active_variant.agent_loop
    schedule_loop!(loop_b)
    run_round!(loop_b, "r1", "checked")
    converge!
    assert_equal "completed", turn_b.reload.status

    _turn_a, loop_a = open!("and?")
    read = request_of(loop_a).flat_map { |payload| Array(payload["parts"]).map { |part| part["text"] } }.join("\n")
    assert_includes read, "B, check the indexes", "the question B was asked"
    assert_includes read, wrapped(@peer, "Mock: checked"), "and B's answer, as a message from B"
    assert_not_includes read, lead, "never B's per-turn text"
    run_round!(loop_a, "r1", "A answers")
    converge!

    _turn_b2, loop_b2 = open!("B, more?", to: @peer)
    assert_equal @peer, loop_b2.conversation_turn.answering_user
    own = request_of(loop_b2).reject { |payload| payload["role"] == "system" }.first
    assert_equal ["developer", lead], [own["role"], own.dig("parts", 0, "text")],
      "B's own history replays its preface where its request placed it"
  end
end
