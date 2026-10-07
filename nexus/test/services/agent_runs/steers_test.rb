require "test_helper"

# The one waiting room, drained by the loop: a bound steer lands at the NEXT unambiguous model
# boundary on either host, ambiguity keeps it bound rather than steering an arbitrary branch, a
# terminal loop releases what never landed, and a standalone loop's queued word is its follow-up.
class AgentRuns::SteersTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def steer!(agent_run, text: "change course", **over)
    loop_input!(agent_run, acting_user: @human, text: text, **over)
  end

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def run_step!(agent_run, key, behaviour)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == node(agent_run, key).selected_model_invocation_id
    end
    apply_via(admitted.attempt, behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def items(host, type)
    host.conversation_event_items.where(item_type: type).order(:sequence)
  end

  def request_body(node)
    ModelInvocation.find(node.selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
  end

  def request_texts(node)
    request_body(node).content_body_entries.map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
  end

  test "a steer lands on the one ready model task and rides its sealed request" do
    agent_run = seed(model("only", "prompt" => "do the thing"))
    accepted = steer!(agent_run)
    assert_predicate accepted, :accepted?
    assert_equal "steering", accepted.value.state, "a loop host binds every steer to its one turn"
    start!(agent_run)

    schedule!(agent_run)

    only = node(agent_run, "only")
    assert_equal ["do the thing", "change course"], request_texts(only),
      "the directive rides as its own final user message — the sealed request IS the record"
    assert_predicate request_body(only), :sealed?
    assert_equal 0, agent_run.reload.conversation_inputs.count, "the row and its body are gone"

    landed = items(agent_run, "input_materialized").sole
    assert_equal accepted.value.public_id, landed.payload.fetch("input_public_id")
    assert_equal "only", landed.payload.fetch("task_key")
    assert_equal agent_run.public_id, landed.payload.fetch("run_public_id")
    assert_not landed.payload.key?("turn_public_id"), "a standalone loop has no turn row to name"
    rendered = ConversationEventItem::PublicProjection.render(landed)
    assert_equal({ type: "run", public_id: agent_run.public_id }, rendered[:resource])
  end

  # The conversation host: the steer binds to the loop-backed TURN through
  # the conversation's door, and the loop reads it through the seam.
  test "a loop-backed loop drains the steer bound to its turn, and says so on its conversation" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.authored(
      agent_run: seam.agent_run, steps: [model("only", "prompt" => "reply")]
    ))
    assert_predicate appended, :applied?

    accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: @human, kind: "message", role: "user",
      entries: [{ "text" => "shorter, please" }], visible_in_context: true,
      delivery_mode: "steer", context_mode: nil, context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      expected_steering_run_public_id: seam.agent_run.public_id,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate accepted, :accepted?
    assert_equal seam.turn.id, accepted.value.steering_target_turn_id
    assert_equal [accepted.value.id], seam.agent_run.steering_inputs.map(&:id),
      "the one finder reads the turn's own rows through the seam"
    clear_enqueued_jobs

    schedule!(seam.agent_run)

    assert_equal ["reply", "shorter, please"], request_texts(node(seam.agent_run, "only"))
    assert_not ConversationInput.exists?(accepted.value.id)
    assert_empty seam.agent_run.conversation_event_items, "a loop-backed loop hosts nothing"
    landed = items(conversation, "input_materialized").sole
    assert_equal seam.turn.public_id, landed.payload.fetch("turn_public_id")
    assert_equal seam.agent_run.public_id, landed.payload.fetch("run_public_id")
    assert_equal "only", landed.payload.fetch("task_key")
    rendered = ConversationEventItem::PublicProjection.render(landed)
    assert_equal({ type: "conversation", public_id: conversation.public_id }, rendered[:resource])
  end

  test "an ambiguous boundary keeps the steer bound" do
    agent_run = seed(parallel(model("left"), model("right")), model("merge"))
    assert_predicate steer!(agent_run), :accepted?
    start!(agent_run)

    schedule!(agent_run)

    assert_equal ["p"], request_texts(node(agent_run, "left")),
      "two ready model tasks means `next` names neither — nothing is steered"
    assert_equal ["p"], request_texts(node(agent_run, "right"))
    assert_equal 1, agent_run.reload.steering_inputs.count
    assert_equal 0, items(agent_run, "input_materialized").count
  end

  test "a steer arriving mid-flight waits for the next boundary" do
    agent_run = seed(model("first", "prompt" => "first"), model("second", "prompt" => "second"))
    start!(agent_run)
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "first").status

    assert_predicate steer!(agent_run), :accepted?
    schedule!(agent_run)
    assert_equal 1, agent_run.reload.steering_inputs.count,
      "a provider call is already in flight; the steer is not for that round"

    run_step!(agent_run, "first", sse_success("done"))
    schedule!(agent_run)

    assert_equal ["first", "Mock: done", "second", "change course"], request_texts(node(agent_run, "second")),
      "the next round replays the one before it, then the directive lands last"
    assert_equal 0, agent_run.reload.conversation_inputs.count
  end

  test "the queue keeps order, drains together, and every entry is its own message" do
    agent_run = seed(model("only", "prompt" => "do the thing"))
    assert_predicate steer!(agent_run, text: "first correction"), :accepted?
    assert_predicate steer!(agent_run, text: "second correction"), :accepted?
    assert_predicate steer!(agent_run, text: "third correction"), :accepted?
    start!(agent_run)

    schedule!(agent_run)

    assert_equal ["do the thing", "first correction", "second correction", "third correction"],
      request_texts(node(agent_run, "only")),
      "a user correcting themselves twice gets both corrections, in order"
    assert_equal 0, agent_run.conversation_inputs.count
    assert_equal 3, items(agent_run, "input_materialized").count
  end

  test "the door is bounded at admission, and a cancel is the row's DELETE" do
    agent_run = seed(model("only"))
    AgentRun::INPUT_QUEUE_LIMIT.times do |n|
      assert_predicate steer!(agent_run, text: "correction #{n}"), :accepted?
    end
    assert_equal :input_queue_full, steer!(agent_run, text: "one too many").outcome

    victim = agent_run.steering_inputs.first
    canceled = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: agent_run, acting_user: @human, input_public_id: victim.public_id
    ))
    assert_predicate canceled, :accepted?
    assert items(agent_run, "input_deleted").sole.payload.fetch("steer_canceled")
    assert_predicate steer!(agent_run, text: "fits again"), :accepted?
  end

  test "a bound steer is not editable, so the words at the peek are the words typed" do
    agent_run = seed(model("only"))
    steer = steer!(agent_run).value

    edited = Conversations::Inputs::Update.call(Conversations::Inputs::Update::Command.new(
      host: agent_run, input_public_id: steer.public_id, acting_user: @human,
      expected_lock_version: nil, entries: [{ "text" => "other words" }],
      visible_in_context: nil, context_mode: nil, context_options: nil,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))

    assert_equal :steering_held, edited.outcome
    assert_equal "change course", steer.reload.text
  end

  test "a terminal loop releases its bound steers to the queue, and its door closes" do
    agent_run = seed(model("only"))
    steer = steer!(agent_run).value
    start!(agent_run)

    # The loop ends without ever reaching an unambiguous boundary for it.
    AgentRuns::Transition.agent_run(agent_run, status: "completed",
      completed_at: Time.current)

    steer.reload
    assert_equal "pending", steer.state,
      "a directive the caller typed falls back to the queue, never onto the floor"
    assert_nil steer.steering_target_turn_id
    released = items(agent_run, "input_edited").sole
    assert_equal steer.public_id, released.payload.fetch("input_public_id")
    assert_equal "steer_target_settled", released.payload.fetch("reason")
    assert_equal "pending", released.payload.fetch("state")

    assert_equal :run_settled, steer!(agent_run, text: "too late").outcome
    projected = AgentAPI::AgentRunPresenter.full(agent_run.reload)
    assert_equal({ status: "completed" }, projected[:turn])
    assert_equal({ limit: AgentRun::INPUT_QUEUE_LIMIT, held: 1 }, projected[:input_queue],
      "the released row stays readable on a host with no next boundary")
    assert_not projected.key?(:steers)
  end

  test "a hold keeps the steer bound: the reopened loop drains it at its next boundary" do
    agent_run = seed(model("only"))
    steer = steer!(agent_run).value
    start!(agent_run)

    AgentRuns::Transition.agent_run(agent_run, status: "needs_attention",
      attention_reason: "halt_failure")

    assert_equal "steering", steer.reload.state, "a halt is not terminal"
    assert_empty items(agent_run, "input_edited")
    assert_equal({ status: "failed", failure_reason_key: "halt_failure" },
      AgentAPI::AgentRunPresenter.full(agent_run)[:turn])
  end

  # The one-turn host's reading of `queue`: a pending word is the loop's FOLLOW-UP, planted as one
  # more mainline round at quiescence, and `completed` means the queue was empty there.
  test "a queued word plants a follow-up round before the loop completes, and drains into it" do
    agent_run = seed(model("ask", "prompt" => "first question"))
    start!(agent_run)
    schedule!(agent_run)
    queued = steer!(agent_run, text: "and then this", delivery_mode: "queue").value
    assert_equal "pending", queued.state, "a queued word waits for the boundary"

    run_step!(agent_run, "ask", sse_success("answered"))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    assert_equal "running", agent_run.reload.status, "an unread word is not an answer"
    assert_equal "steering", queued.reload.state, "the head is bound at quiescence"
    bound = items(agent_run, "input_edited").sole
    assert_equal "follow_up_bound", bound.payload.fetch("reason")
    assert_equal "steering", bound.payload.fetch("state")
    plant = agent_run.agent_run_tasks.where("node_key LIKE 'w%'").sole
    assert_equal "queued", plant.status
    assert_equal ["ask"], plant.input_from_node_keys
    assert_equal plant.id, agent_run.deliverable_node_id, "the answer moves with the plant"
    assert_enqueued_with(job: AgentRuns::ScheduleJob, args: [agent_run.id])
    clear_enqueued_jobs

    schedule!(agent_run)
    assert_equal "running", plant.reload.status
    assert_equal "and then this", request_texts(plant).last, "the word lands in the planted round"
    assert_equal plant.node_key, items(agent_run, "input_materialized").sole.payload.fetch("task_key")

    run_step!(agent_run, plant.node_key, sse_success("done"))
    schedule!(agent_run)
    assert_equal "completed", agent_run.reload.status, "completed means the queue was empty"
    assert_equal 0, agent_run.conversation_inputs.count
  end

  test "a planted round whose word was withdrawn settles skipped, and the loop completes" do
    agent_run = seed(model("ask", "prompt" => "first question"))
    start!(agent_run)
    schedule!(agent_run)
    queued = steer!(agent_run, text: "never mind", delivery_mode: "queue").value
    run_step!(agent_run, "ask", sse_success("answered"))
    schedule!(agent_run)
    plant = agent_run.agent_run_tasks.where("node_key LIKE 'w%'").sole

    # Withdrawn between the quiescence pass and the schedule.
    ConversationInput.where(id: queued.id).each(&:destroy!)
    schedule!(agent_run)

    assert_equal "skipped", plant.reload.status, "nothing to ask, no attempt charged"
    assert_nil plant.selected_model_invocation_id
    assert_equal node(agent_run, "ask").id, agent_run.reload.deliverable_node_id,
      "the answer moves back to the round that gave it"
    assert_equal "completed", agent_run.status
  end

  test "pause(force) stops the model step NOW, spares the rest, and re-queues for resume" do
    agent_run = seed(
      parallel(model("thinking", "prompt" => "long think"), ask("gate", "timeout_ms" => 6.hours.in_milliseconds)),
      model("after")
    )
    start!(agent_run)
    schedule!(agent_run)
    thinking = node(agent_run, "thinking")
    invocation = ModelInvocation.find(thinking.selected_model_invocation_id)

    result = AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    ))
    assert_predicate result, :accepted?
    assert_equal "canceled", invocation.reload.status
    assert_equal "interrupted", invocation.failure_reason_key
    assert_equal "dispatched", node(agent_run, "gate").status,
      "a parked await is spared — pause stops reasoning, not the world"
    assert_equal "paused", agent_run.reload.status,
      "the graph stops ADVANCING — nothing queued starts until resume"

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    thinking.reload
    assert_equal "queued", thinking.status,
      "a pause is NOT a failure — the step re-queues under a fresh generation"
    assert_equal 1, thinking.execution_generation
    assert_nil thinking.error_key
    assert_equal "paused", agent_run.reload.status

    # Forcing an already-paused loop is the escalation arm, not an error.
    again = AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    ))
    assert_predicate again, :accepted?
    graceful = AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    ))
    assert_equal :not_pausable, graceful.outcome,
      "a plain pause of a paused loop is a conflict — someone else paused it"
  end

  test "pause(force) + steer + resume is the Esc gesture: stop, do this instead" do
    agent_run = seed(model("main", "prompt" => "original plan"))
    start!(agent_run)
    schedule!(agent_run)

    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    )), :accepted?
    assert_predicate steer!(agent_run, text: "actually, do it in Rust"), :accepted?

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "paused", agent_run.reload.status
    assert_equal "queued", node(agent_run, "main").status,
      "the aborted step re-queued; nothing mints while paused"

    assert_predicate AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)

    assert_equal ["original plan", "actually, do it in Rust"],
      request_texts(node(agent_run, "main")),
      "the redirect rides the re-minted request — pause, steer, resume, one client key"
  end

  test "a wide resume keeps the steer bound: two re-queued tasks are an ambiguous boundary" do
    agent_run = seed(
      parallel(model("left", "prompt" => "left branch"), model("right", "prompt" => "right branch")),
      model("merge")
    )
    start!(agent_run)
    schedule!(agent_run)

    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    )), :accepted?
    assert_predicate steer!(agent_run, text: "redirect"), :accepted?
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs

    AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    schedule!(agent_run)

    marker = AgentRuns::InputComposition::ABORT_MARKER
    assert_equal [marker, "left branch"], request_texts(node(agent_run, "left"))
    assert_equal [marker, "right branch"], request_texts(node(agent_run, "right"))
    assert_equal 1, agent_run.steering_inputs.count,
      "two ready model tasks means `next` names neither — with no mainline to " \
      "sharpen the boundary the steer waits rather than steering an " \
      "arbitrary branch"
    # And BECAUSE it waits, the marker fires: the discrimination is
    # "does the user's message follow in THIS request", not merely
    # "does one exist somewhere in the queue".
  end

  test "a refused body leaves NO phantom row behind" do
    agent_run = seed(model("only"))
    before = agent_run.conversation_inputs.count

    refused = steer!(agent_run, text: "bad text")
    assert_equal :unsupported_text, refused.outcome
    assert_equal before, agent_run.conversation_inputs.count,
      "the savepoint takes the row back — a phantom would render, count " \
      "against the bound, and be released at loop end (audit)"
  end

  test "a forced pause never spends the auto-retry budget" do
    agent_run = seed(model("main", "retry" => 1))
    start!(agent_run)
    schedule!(agent_run)

    3.times do
      AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
        agent_run: agent_run, acting_user: @human, force: true
      ))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
        agent_run: agent_run, acting_user: @human
      ))
      clear_enqueued_jobs
      schedule!(agent_run)
    end

    main = node(agent_run, "main")
    assert_equal 3, main.execution_generation, "the fence bumped every re-arm"
    assert_equal 0, main.auto_retries_used,
      "a pause is NOT a failure — the documented budget is intact (audit)"
  end

  test "the loop door admits a message from a user only, and nothing that names a model or an assembly" do
    agent_run = seed(model("only"))

    assert_equal :invalid, steer!(agent_run, kind: "direct_reply").outcome,
      "the loop is already replying"
    assert_equal :invalid, steer!(agent_run, role: "system").outcome
    named = steer!(agent_run, provider_id: "dev", model_ref: "mock-text")
    assert_equal :invalid, named.outcome
    assert_equal %i[provider_id model_ref], named.record.errors.map(&:attribute),
      "refused by name, never silently dropped"
  end
end
