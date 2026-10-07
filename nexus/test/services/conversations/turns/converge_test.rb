require "test_helper"

# The converger over both frontiers: the reply frontier as it was, and the loop frontier as a
# predicate on the PAIR (loop row, variant row) — three JOIN-derived arms on the named indexes, each
# idempotent by the rows' own state. A held tail may move directly from a
# settled failure to its recovered final state. Every loop-backed case rides
# the seam fixture; a standalone loop is on no frontier at all.
class Conversations::Turns::ConvergeTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def seam!(**over)
    create_run_backed_turn(conversation: @conversation.reload, acting_user: @human, **over)
  end

  # The seam fixture carries no seed, so the first authored envelope is
  # the seed: its end is the deliverable by construction.
  def append!(agent_run, steps) = grow!(agent_run, *steps)

  def schedule!(agent_run)
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run.reload
  end

  def run_step!(agent_run, behaviour = sse_success("the answer"))
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.agent_run_id == agent_run.id
    end
    raise "step not admitted" if admitted.nil?

    apply_via(admitted.attempt, behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    agent_run.reload
  end

  def hold!(agent_run, reason: "halt_failure")
    AgentRuns::Transition.agent_run(agent_run, status: "needs_attention", attention_reason: reason)
  end

  def converge(**opts) = Conversations::Turns::Converge.call(**opts)

  def accept!(text:, delivery_mode: "queue")
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @human, kind: "message", role: "user",
      entries: [{ "text" => text }], visible_in_context: true, delivery_mode: delivery_mode,
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?
    result.value
  end

  # The settle's own narration: a `turn_status` that carries `status` was written under the
  # conversation lock.
  def settled_items
    @conversation.conversation_event_items.where(item_type: "turn_status")
      .order(:sequence).map(&:payload).select { |payload| payload.key?("status") }
  end

  # ── SETTLE ──────────────────────────────────────────────────────────────

  test "a completed loop settles its turn completed, with the deliverable's answer as the content" do
    seam = seam!
    append!(seam.agent_run, [model("only")])
    schedule!(seam.agent_run)
    run_step!(seam.agent_run)
    agent_run = schedule!(seam.agent_run)
    assert_equal "completed", agent_run.status
    assert_equal "running", seam.variant.reload.status, "the loop lock never writes the turn's row"

    result = nil
    assert_enqueued_with(job: Conversations::Inputs::DrainJob, args: [@conversation.id]) do
      result = converge
    end
    assert_predicate result, :accepted?
    assert_equal 1, result.value[:recorded]

    seam.variant.reload
    seam.turn.reload
    @conversation.reload
    assert_equal "completed", seam.variant.status
    assert_equal "completed", seam.turn.status
    assert_equal seam.variant.id, seam.turn.active_variant_id
    assert_nil @conversation.active_turn_id, "the lane is idle again"
    assert_equal 1, @conversation.context_revision, "a visible completed turn is context"

    content = seam.variant.content_bodies.find_by!(role: "content")
    assert_predicate content, :sealed?
    assert_equal "Mock: the answer", content.effective_text, "the deliverable's output, entry-copied"
    assert_equal "Mock: the answer", seam.variant.content_preview

    settled = settled_items.sole
    assert_equal "completed", settled.fetch("status")
    assert_equal "completed", settled.fetch("variant_status")
    assert_equal seam.turn.public_id, settled.fetch("turn_public_id")
    assert_equal "direct_reply", settled.fetch("turn_kind")
    assert_equal seam.variant.public_id, settled.fetch("variant_public_id")
    assert_equal agent_run.public_id, settled.fetch("run_public_id")
    assert_not settled.key?("failure_reason_key")

    assert_equal 0, converge.value[:recorded], "once the write lands the pair leaves the frontier"
  end

  test "a hold settles the turn failed with the reason, and keeps a bound steer bound" do
    seam = seam!
    steer = accept!(text: "shorter", delivery_mode: "steer")
    assert_equal seam.turn.id, steer.steering_target_turn_id

    hold!(seam.agent_run)
    assert_equal 1, converge.value[:recorded]

    seam.variant.reload
    seam.turn.reload
    assert_equal "failed", seam.variant.status
    assert_equal "failed", seam.turn.status
    assert_nil @conversation.reload.active_turn_id, "the gate opens on a hold"
    assert_equal 0, @conversation.context_revision, "a failed turn is not context"

    settled = settled_items.sole
    assert_equal "failed", settled.fetch("status")
    assert_equal "halt_failure", settled.fetch("failure_reason_key")
    assert_equal "steering", steer.reload.state,
      "a hold is not terminal: the steer waits for the reopened loop's next boundary"
    assert_equal 0, converge.value[:recorded], "the hold at rest matches no arm"
  end

  test "a steer accepted after loop completion returns to the queue when its turn settles" do
    seam = seam!
    append!(seam.agent_run, [model("only")])
    schedule!(seam.agent_run)
    run_step!(seam.agent_run)
    schedule!(seam.agent_run)
    assert_equal "completed", seam.agent_run.reload.status
    assert_equal "running", seam.turn.reload.status

    steer = accept!(text: "late correction", delivery_mode: "steer")
    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_equal "pending", steer.reload.state,
      "the completed engine has no model boundary left to read this input"
    assert_nil steer.steering_target_turn_id

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal "late correction", @conversation.conversation_turns.order(:position).last
      .active_variant.content_bodies.find_by!(role: "content").effective_text
  end

  test "a reasoned cancel settles failed with the loop's reason; a bare cancel settles canceled" do
    reasoned = seam!
    AgentRuns::Transition.agent_run(reasoned.agent_run, status: "canceled",
      failure_reason: "authority_lost", completed_at: Time.current)
    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", reasoned.turn.reload.status
    assert_equal "authority_lost", settled_items.sole.fetch("failure_reason_key")

    bare = seam!
    AgentRuns::Transition.agent_run(bare.agent_run, status: "canceled", completed_at: Time.current)
    assert_equal 1, converge.value[:recorded]
    assert_equal "canceled", bare.turn.reload.status
    assert_equal "canceled", bare.variant.reload.status
    assert_equal "canceled", settled_items.last.fetch("status")
    assert_not settled_items.last.key?("failure_reason_key")
  end

  test "a forced authority cancellation retains its own failure reason when settling" do
    seam = seam!
    seam.agent_run.with_lock do
      AgentRuns::Stop.terminate(seam.agent_run, failure_reason: "authority_lost")
    end
    schedule!(seam.agent_run)
    assert_predicate seam.agent_run, :stopped?
    assert_equal "canceled", seam.agent_run.status

    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", seam.turn.reload.status
    assert_equal "authority_lost", settled_items.sole.fetch("failure_reason_key")
  end

  test "stopping a completed loop before its answer is published prevents adoption" do
    seam = seam!
    append!(seam.agent_run, [model("only")])
    schedule!(seam.agent_run)
    run_step!(seam.agent_run)
    schedule!(seam.agent_run)
    assert_equal "completed", seam.agent_run.status
    assert_equal "running", seam.variant.reload.status

    assert_predicate AgentRuns::Stop.stop_now(seam.agent_run), :accepted?
    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.agent_run.reload.status, "the execution's terminal fact is retained"
    assert_equal "canceled", seam.turn.reload.status
    assert_equal "source_stopped", settled_items.sole.fetch("failure_reason_key")
    assert_empty seam.variant.content_bodies.where(role: "content")
    assert_equal 0, @conversation.reload.context_revision
  end

  test "the loop's status write wakes the converger, on the conversation, after commit" do
    seam = seam!
    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "agent_run_id" => seam.agent_run.id }]) do
      hold!(seam.agent_run)
    end
    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "agent_run_id" => seam.agent_run.id }]) do
      AgentRuns::Transition.agent_run(seam.agent_run, attention_reason: "awaiting_human")
    end
    assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) do
      AgentRuns::Transition.agent_run(seam.agent_run, revision: 7)
    end
  end

  test "a standalone loop wakes nothing and no turn transition is owed" do
    agent_run = AgentRun.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) { hold!(agent_run) }

    result = converge
    assert_equal 2, result.value[:scanned], "each live-loop source window charges the standalone row"
    assert_equal 0, result.value[:recorded]
    assert_equal "needs_attention", agent_run.reload.status
    assert_equal "failed", agent_run.turn_shape.status, "its turn shape is derived at read time"
  end

  # THE REPLY IS FINAL, THE LOOP IS NOT: the settle arm reads `delivered_at` beside the three
  # statuses, adopts the deliverable's output, and the loop's later terminal rewrites nothing.
  test "a delivered loop settles its turn completed while it runs on, and its later terminal rewrites nothing" do
    seam = seam!
    append!(seam.agent_run, [model("answer")])
    schedule!(seam.agent_run)
    run_step!(seam.agent_run, sse_success("the reply"))
    AgentRuns::Transition.agent_run(seam.agent_run.reload, status: "running")
    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "agent_run_id" => seam.agent_run.id }]) do
      AgentRuns::Transition.agent_run(seam.agent_run, delivered_at: Time.current)
    end

    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_equal "completed", seam.variant.reload.status
    assert_equal "Mock: the reply", seam.variant.content_bodies.find_by!(role: "content").effective_text
    assert_equal "running", seam.agent_run.reload.status, "the loop is still finishing background work"
    assert_nil @conversation.reload.active_turn_id
    assert_equal 0, converge.value[:recorded]

    hold!(seam.agent_run)
    assert_equal 0, converge.value[:recorded], "a hold after delivery is the loop's alone"
    assert_equal "completed", seam.turn.reload.status
    AgentRuns::Transition.agent_run(seam.agent_run, status: "completed", completed_at: Time.current,
      attention_reason: nil)
    assert_equal 0, converge.value[:recorded]
    assert_equal "completed", seam.variant.reload.status, "the settled variant is never rewritten"
    assert_equal 1, settled_items.length, "one settle narrated, on delivery"
  end

  test "REPLACE exempts a delivered loop behind a successor, and still replaces a held one" do
    delivered = seam!
    AgentRuns::Transition.agent_run(delivered.agent_run, delivered_at: Time.current)
    converge
    assert_equal "completed", delivered.turn.reload.status
    accept!(text: "and then")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

    assert_equal 0, converge.value[:recorded]
    assert_equal "running", delivered.agent_run.reload.status,
      "a delivered loop behind a successor is finishing background work, not replaced"
    assert_nil delivered.agent_run.failure_reason

    held = seam!
    hold!(held.agent_run)
    converge
    accept!(text: "start over")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal 1, converge.value[:recorded]
    assert_equal "replaced", held.agent_run.reload.failure_reason
  end

  # ── REOPEN ──────────────────────────────────────────────────────────────

  test "a retried loop reopens its hold-settled tail turn, and the lane closes again" do
    seam = seam!
    hold!(seam.agent_run)
    converge
    assert_equal "failed", seam.turn.reload.status

    AgentRuns::Transition.agent_run(seam.agent_run, status: "running", attention_reason: nil)
    assert_equal 1, converge.value[:recorded]

    seam.variant.reload
    seam.turn.reload
    assert_equal "running", seam.variant.status
    assert_equal "running", seam.turn.status
    assert_equal seam.turn.id, @conversation.reload.active_turn_id, "the pointer is re-taken"
    assert_equal "running", settled_items.last.fetch("status")

    AgentRuns::Transition.agent_run(seam.agent_run, status: "completed", completed_at: Time.current)
    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_nil @conversation.reload.active_turn_id
  end

  test "retry completes before reopen convergence" do
    seam = seam!
    append!(seam.agent_run, [model("only")])
    schedule!(seam.agent_run)
    run_step!(seam.agent_run, json_response(400, { "error" => "bad" }))
    schedule!(seam.agent_run)
    converge
    assert_equal "failed", seam.turn.reload.status

    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: seam.agent_run, task_key: "only", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    schedule!(seam.agent_run)
    run_step!(seam.agent_run)
    schedule!(seam.agent_run)
    assert_equal "completed", seam.agent_run.reload.status
    assert_equal "failed", seam.variant.reload.status, "the reopen job has not run"

    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_equal "Mock: the answer", seam.variant.reload.content_preview
    assert_equal 0, converge.value[:recorded], "the repaired pair leaves the frontier"
  end

  test "cancel before reopen convergence settles once without replacing a newer candidate" do
    seam = seam!
    hold!(seam.agent_run)
    converge
    AgentRuns::Transition.agent_run(seam.agent_run, status: "canceling")
    AgentRuns::Transition.agent_run(seam.agent_run, status: "canceled", completed_at: Time.current)
    assert_equal 1, converge.value[:recorded]
    assert_equal "canceled", seam.turn.reload.status
    assert_equal 0, converge.value[:recorded]

    newer = seam!
    hold!(newer.agent_run)
    converge
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: newer.turn.public_id,
      entries: [{ "text" => "my answer" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?
    AgentRuns::Transition.agent_run(newer.agent_run, status: "completed", completed_at: Time.current)
    assert_equal 0, converge.value[:recorded]
    assert_equal "failed", newer.variant.reload.status
    assert_equal edited.value.id, newer.turn.reload.active_variant_id
  end

  test "reopen is refused behind an edit: a person's answer stands" do
    seam = seam!
    hold!(seam.agent_run)
    converge

    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: seam.turn.public_id,
      entries: [{ "text" => "my own answer" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?
    assert_equal "completed", seam.turn.reload.status

    AgentRuns::Transition.agent_run(seam.agent_run, status: "running", attention_reason: nil)
    assert_equal 0, converge.value[:recorded]
    assert_equal "failed", seam.variant.reload.status, "the seam's variant is terminal and never rewritten"
    assert_equal "completed", seam.turn.reload.status
    assert_equal edited.value.id, seam.turn.active_variant_id
    assert_nil @conversation.reload.active_turn_id
  end

  test "the adjudication verbs read the seam under the lock: on the rendered variant a retry proceeds and reopens" do
    seam = seam!
    append!(seam.agent_run, [model("only")])
    schedule!(seam.agent_run)
    run_step!(seam.agent_run, json_response(400, { "error" => "bad" }))
    agent_run = schedule!(seam.agent_run)
    assert_equal "needs_attention", agent_run.status
    assert_equal "halt_failure", agent_run.attention_reason
    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", seam.turn.reload.status
    assert_not_predicate agent_run, :overridden?, "the loop's variant is what the turn shows"

    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "only", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    assert_equal "running", agent_run.reload.status
    assert_equal 1, converge.value[:recorded], "REOPEN: the person's retry runs the same turn again"
    assert_equal "running", seam.turn.reload.status
    assert_equal seam.turn.id, @conversation.reload.active_turn_id

    hold!(agent_run)
    converge
    Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: seam.turn.public_id,
      entries: [{ "text" => "my own answer" }], acting_user: @human
    ))
    assert_predicate agent_run.reload, :overridden?
    abandoned = AgentRuns::Tasks::Abandon.call(AgentRuns::Tasks::Abandon::Command.new(
      agent_run: agent_run, task_key: "only", acting_user: @human
    ))
    assert_equal :not_adjudicable, abandoned.outcome
    assert_nil seam.agent_run.agent_run_tasks.find_by!(node_key: "only").failure_resolution,
      "the refusal precedes the write"
    assert_equal "needs_attention", agent_run.reload.status
  end

  # The one-worker ordering the four-world gate observed: the abandon's
  # status write wakes this converger after commit, and the queue may run
  # it BEFORE any scheduler pass. An abandoned sole deliverable must
  # therefore never commit as `running` behind its hold-settled turn — the
  # REOPEN arm would flip the variant, the later re-hold would settle it
  # failed a second time, and the person's next word (typed between the
  # two settles) would read as pre-hold and wait forever as `run_held`.
  test "an abandoned sole deliverable never reopens its hold-settled turn: the loop re-holds in the abandon's commit and the next word replaces it" do
    seam = seam!
    append!(seam.agent_run, [model("only")])
    schedule!(seam.agent_run)
    run_step!(seam.agent_run, json_response(400, { "error" => "bad" }))
    agent_run = schedule!(seam.agent_run)
    assert_equal "halt_failure", agent_run.attention_reason
    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", seam.turn.reload.status
    settled_at = seam.variant.reload.updated_at

    clear_enqueued_jobs
    abandoned = nil
    # The commit wakes the converger (the loop's status changed) and no
    # scheduler: the ordering this pin stages is the queue's real one.
    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "agent_run_id" => seam.agent_run.id }]) do
      assert_no_enqueued_jobs(only: AgentRuns::ScheduleJob) do
        abandoned = AgentRuns::Tasks::Abandon.call(AgentRuns::Tasks::Abandon::Command.new(
          agent_run: agent_run, task_key: "only", acting_user: @human
        ))
      end
    end
    assert_predicate abandoned, :accepted?
    agent_run.reload
    assert_equal "needs_attention", agent_run.status, "judged under the adjudication's own lock"
    assert_equal "deliverable_unresolved", agent_run.attention_reason

    # The converger first, as the queue may run it.
    perform_enqueued_jobs(only: Conversations::Turns::ConvergeJob)
    assert_equal 0, converge.value[:recorded], "no arm matches: no running loop behind the failed tail"
    seam.variant.reload
    assert_equal "failed", seam.variant.status, "REOPEN never fired"
    assert_equal settled_at, seam.variant.updated_at, "the one settle stands; nothing re-settled the variant"
    assert_equal "failed", seam.turn.reload.status
    assert_equal 1, settled_items.length, "one settle narrated, on the halt"

    # Then the scheduler pass, level-triggered over a held loop: no change.
    schedule!(agent_run)
    assert_equal "deliverable_unresolved", agent_run.reload.attention_reason
    assert_equal settled_at, seam.variant.reload.updated_at

    # A word typed after the abandon is a post-settle word: it materializes
    # (never `run_held`) and the REPLACE arm stops the held loop.
    accept!(text: "carry on")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id),
      "the person's next word is the repair, not a row held behind the hold"
    assert_equal 2, @conversation.conversation_turns.count
    assert_empty @conversation.conversation_event_items.where(item_type: "input_blocked")
    assert_equal 1, converge.value[:recorded]
    agent_run.reload
    assert_equal "canceling", agent_run.status
    assert_equal "replaced", agent_run.failure_reason
    assert_equal "failed", seam.variant.reload.status, "the terminal variant is never rewritten"
  end

  # ── REPLACE ─────────────────────────────────────────────────────────────

  test "a successor behind a held loop stops it replaced — the one site of the word" do
    seam = seam!
    hold!(seam.agent_run)
    converge
    accept!(text: "never mind, start over")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id),
      "a post-settle word is the repair"
    assert_equal 2, @conversation.conversation_turns.count

    assert_equal 1, converge.value[:recorded]
    seam.agent_run.reload
    assert_equal "canceling", seam.agent_run.status
    assert_equal "replaced", seam.agent_run.failure_reason
    assert_equal "failed", seam.variant.reload.status, "the terminal variant is never rewritten"
    assert_equal "failed", seam.turn.reload.status

    AgentRuns::EvaluateQuiescence.call(seam.agent_run)
    assert_equal "canceled", seam.agent_run.reload.status
    assert_equal 0, converge.value[:recorded], "variant terminal, loop terminal: off the frontier"
    assert_equal "failed", seam.turn.reload.status
  end

  test "a loop a retry flipped running behind a successor is replaced, never reopened" do
    seam = seam!
    hold!(seam.agent_run)
    converge
    accept!(text: "next")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    AgentRuns::Transition.agent_run(seam.agent_run, status: "running", attention_reason: nil)

    assert_equal 1, converge.value[:recorded]
    assert_equal "canceling", seam.agent_run.reload.status
    assert_equal "replaced", seam.agent_run.failure_reason
    assert_equal "failed", seam.turn.reload.status, "no reopen flips a turn behind a successor"
    assert_nil @conversation.reload.active_turn_id
  end

  # ── The expired ask holds ───────────────────────────────────────────────

  test "a model's expired ask holds the loop, and the hold settles the turn with the ask named" do
    seam = seam!(run_status: "pending")
    append!(seam.agent_run, [model("round1", "tools" => [Nexus::Tools::ASK])])
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: seam.agent_run, acting_user: @human
    ))
    schedule!(seam.agent_run)
    run_step!(seam.agent_run, sse_success("asking", tool_calls: [
      { id: "call_c", name: "ask", arguments: { prompt: "Which database?" }.to_json },
    ]))
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentRuns::AskJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    end
    ask = seam.agent_run.agent_run_tasks.where(type: AgentRunTasks::AwaitTask.sti_name).sole
    assert_equal "awaiting_input", ask.status
    assert_equal "halt", ask.on_failure, "a tokenless ask compiles halt whatever was authored"

    AgentRunTask.where(id: ask.id).update_all(await_started_at: (AgentRunTasks::AwaitTask::MAX_HOLD + 1.second).ago)
    expired = AgentRuns::Parks::Settle.call(node: ask.reload, timeout: true)
    assert_predicate expired, :applied?
    AgentRuns::EvaluateQuiescence.call(seam.agent_run.reload)
    AgentRuns::EvaluateQuiescence.call(seam.agent_run.reload)
    assert_equal "needs_attention", seam.agent_run.reload.status
    assert_equal "halt_failure", seam.agent_run.attention_reason

    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", seam.turn.reload.status
    settled = settled_items.last
    assert_equal "halt_failure", settled.fetch("failure_reason_key")
    assert_equal "await_timeout", settled.fetch("error_key")
    assert_equal [ask.node_key], settled.fetch("blocked_task_keys")
  end

  # ── The plans ───────────────────────────────────────────────────────────

  # Retained terminal history stays off the actual recovery sources. The
  # companion frontier test also pins full windows and bounded pair probes.
  test "each arm reads its named index and walks neither table" do
    seed_settled_history!(count: 1500)
    sources = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      sources << [sql, payload[:binds].dup] if sql.start_with?("SELECT") && sql.include?("LIMIT")
    end
    begin
      ApplicationRecord.uncached { converge }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    settle = explain(*sources.find { |sql, _| sql.include?('FROM "conversation_turn_variants"') })
    assert_match(/index_conversation_turn_variants_settle_frontier/, settle)
    assert_no_match(/Seq Scan on conversation_turn_variants/, settle)

    loop_sources = sources.select { |sql, _| sql.include?('FROM "agent_runs"') }
    assert_equal 2, loop_sources.length
    loop_sources.each do |sql, binds|
      plan = explain(sql, binds)
      assert_match(/index_agent_runs_stop_frontier/, plan)
      assert_no_match(/Seq Scan on agent_runs|Sort|Filter:/, plan)
    end
  end

  private

    def seed_settled_history!(count:)
      now = Time.current
      actor = Speakers::Resolve.member(account: @account, user: @human)
      history = Conversation.create!(workspace: @workspace, creating_user: @human)
      turn_ids = ConversationTurn.insert_all!(Array.new(count) do |position|
        { account_id: @account.id, conversation_id: history.id, position: position,
          kind: "direct_reply", role: "assistant", status: "completed",
          speaker_id: actor.id, control_owner_user_id: @human.id,
          answering_user_id: history.answering_user_id,
          created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      variant_ids = ConversationTurnVariant.insert_all!(turn_ids.map do |turn_id|
        { account_id: @account.id, conversation_turn_id: turn_id, position: 0,
          status: "completed", source: "run", created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      AgentRun.insert_all!(variant_ids.map do |variant_id|
        { account_id: @account.id, workspace_id: @workspace.id, creating_user_id: @human.id,
          status: "completed", conversation_turn_variant_id: variant_id, approval_mode: "bypass",
          created_at: now, updated_at: now }
      end)
      ApplicationRecord.lease_connection.execute(
        "ANALYZE conversation_turns, conversation_turn_variants, agent_runs"
      )
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds).join("\n")
    end
end
