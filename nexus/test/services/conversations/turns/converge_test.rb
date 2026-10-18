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
  def append!(run, steps) = grow!(run, *steps)

  def schedule!(run)
    clear_enqueued_jobs
    Runs::ScheduleReady.call(run_id: run.id)
    run.reload
  end

  def run_step!(run, behaviour = sse_success("the answer"))
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.run_id == run.id
    end
    raise "step not admitted" if admitted.nil?

    apply_via(admitted.attempt, behaviour)
    Runs::ConvergeTerminalSteps.call
    run.reload
  end

  def hold!(run, reason: "halt_failure")
    Runs::Transition.run(run, status: "needs_attention", attention_reason: reason)
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
    @conversation.event_items.where(item_type: "turn_status")
      .order(:sequence).map(&:payload).select { |payload| payload.key?("status") }
  end

  # ── SETTLE ──────────────────────────────────────────────────────────────

  test "a completed loop settles its turn completed, with the deliverable's answer as the content" do
    seam = seam!
    append!(seam.run, [model("only")])
    schedule!(seam.run)
    run_step!(seam.run)
    run = schedule!(seam.run)
    assert_equal "completed", run.status
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
    assert_equal run.public_id, settled.fetch("run_public_id")
    assert_not settled.key?("failure_reason_key")

    assert_equal 0, converge.value[:recorded], "once the write lands the pair leaves the frontier"
  end

  test "a hold settles the turn failed with the reason, and keeps a bound steer bound" do
    seam = seam!
    steer = accept!(text: "shorter", delivery_mode: "steer")
    assert_equal seam.turn.id, steer.steering_target_turn_id

    hold!(seam.run)
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
    append!(seam.run, [model("only")])
    schedule!(seam.run)
    run_step!(seam.run)
    schedule!(seam.run)
    assert_equal "completed", seam.run.reload.status
    assert_equal "running", seam.turn.reload.status

    steer = accept!(text: "late correction", delivery_mode: "steer")
    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_equal "pending", steer.reload.state,
      "the completed engine has no model boundary left to read this input"
    assert_nil steer.steering_target_turn_id

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal "late correction", @conversation.turns.order(:position).last
      .active_variant.content_bodies.find_by!(role: "content").effective_text
  end

  test "a reasoned cancel settles failed with the loop's reason; a bare cancel settles canceled" do
    reasoned = seam!
    Runs::Transition.run(reasoned.run, status: "canceled",
      failure_reason: "authority_lost", completed_at: Time.current)
    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", reasoned.turn.reload.status
    assert_equal "authority_lost", settled_items.sole.fetch("failure_reason_key")

    bare = seam!
    Runs::Transition.run(bare.run, status: "canceled", completed_at: Time.current)
    assert_equal 1, converge.value[:recorded]
    assert_equal "canceled", bare.turn.reload.status
    assert_equal "canceled", bare.variant.reload.status
    assert_equal "canceled", settled_items.last.fetch("status")
    assert_not settled_items.last.key?("failure_reason_key")
  end

  test "a forced authority cancellation retains its own failure reason when settling" do
    seam = seam!
    seam.run.with_lock do
      Runs::Stop.terminate(seam.run, failure_reason: "authority_lost")
    end
    schedule!(seam.run)
    assert_predicate seam.run, :stopped?
    assert_equal "canceled", seam.run.status

    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", seam.turn.reload.status
    assert_equal "authority_lost", settled_items.sole.fetch("failure_reason_key")
  end

  test "stopping a completed loop before its answer is published prevents adoption" do
    seam = seam!
    append!(seam.run, [model("only")])
    schedule!(seam.run)
    run_step!(seam.run)
    schedule!(seam.run)
    assert_equal "completed", seam.run.status
    assert_equal "running", seam.variant.reload.status

    assert_predicate Runs::Stop.stop_now(seam.run), :accepted?
    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.run.reload.status, "the execution's terminal fact is retained"
    assert_equal "canceled", seam.turn.reload.status
    assert_equal "source_stopped", settled_items.sole.fetch("failure_reason_key")
    assert_empty seam.variant.content_bodies.where(role: "content")
    assert_equal 0, @conversation.reload.context_revision
  end

  test "the loop's status write wakes the converger, on the conversation, after commit" do
    seam = seam!
    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "run_id" => seam.run.id }]) do
      hold!(seam.run)
    end
    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "run_id" => seam.run.id }]) do
      Runs::Transition.run(seam.run, attention_reason: "awaiting_human")
    end
    assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) do
      Runs::Transition.run(seam.run, revision: 7)
    end
  end

  test "a standalone loop wakes nothing and no turn transition is owed" do
    run = Run.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) { hold!(run) }

    result = converge
    assert_equal 2, result.value[:scanned], "each live-loop source window charges the standalone row"
    assert_equal 0, result.value[:recorded]
    assert_equal "needs_attention", run.reload.status
    assert_equal "failed", run.turn_shape.status, "its turn shape is derived at read time"
  end

  # THE REPLY IS FINAL, THE LOOP IS NOT: the settle arm reads `delivered_at` beside the three
  # statuses, adopts the deliverable's output, and the loop's later terminal rewrites nothing.
  test "a delivered loop settles its turn completed while it runs on, and its later terminal rewrites nothing" do
    seam = seam!
    append!(seam.run, [model("answer")])
    schedule!(seam.run)
    run_step!(seam.run, sse_success("the reply"))
    Runs::Transition.run(seam.run.reload, status: "running")
    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "run_id" => seam.run.id }]) do
      Runs::Transition.run(seam.run, delivered_at: Time.current)
    end

    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_equal "completed", seam.variant.reload.status
    assert_equal "Mock: the reply", seam.variant.content_bodies.find_by!(role: "content").effective_text
    assert_equal "running", seam.run.reload.status, "the loop is still finishing background work"
    assert_nil @conversation.reload.active_turn_id
    assert_equal 0, converge.value[:recorded]

    hold!(seam.run)
    assert_equal 0, converge.value[:recorded], "a hold after delivery is the loop's alone"
    assert_equal "completed", seam.turn.reload.status
    Runs::Transition.run(seam.run, status: "completed", completed_at: Time.current,
      attention_reason: nil)
    assert_equal 0, converge.value[:recorded]
    assert_equal "completed", seam.variant.reload.status, "the settled variant is never rewritten"
    assert_equal 1, settled_items.length, "one settle narrated, on delivery"
  end

  test "REPLACE exempts a delivered loop behind a successor, and still replaces a held one" do
    delivered = seam!
    Runs::Transition.run(delivered.run, delivered_at: Time.current)
    converge
    assert_equal "completed", delivered.turn.reload.status
    accept!(text: "and then")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

    assert_equal 0, converge.value[:recorded]
    assert_equal "running", delivered.run.reload.status,
      "a delivered loop behind a successor is finishing background work, not replaced"
    assert_nil delivered.run.failure_reason

    held = seam!
    hold!(held.run)
    converge
    accept!(text: "start over")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal 1, converge.value[:recorded]
    assert_equal "replaced", held.run.reload.failure_reason
  end

  # ── REOPEN ──────────────────────────────────────────────────────────────

  test "a retried loop reopens its hold-settled tail turn, and the lane closes again" do
    seam = seam!
    hold!(seam.run)
    converge
    assert_equal "failed", seam.turn.reload.status

    Runs::Transition.run(seam.run, status: "running", attention_reason: nil)
    assert_equal 1, converge.value[:recorded]

    seam.variant.reload
    seam.turn.reload
    assert_equal "running", seam.variant.status
    assert_equal "running", seam.turn.status
    assert_equal seam.turn.id, @conversation.reload.active_turn_id, "the pointer is re-taken"
    assert_equal "running", settled_items.last.fetch("status")

    Runs::Transition.run(seam.run, status: "completed", completed_at: Time.current)
    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_nil @conversation.reload.active_turn_id
  end

  test "retry completes before reopen convergence" do
    seam = seam!
    append!(seam.run, [model("only")])
    schedule!(seam.run)
    run_step!(seam.run, json_response(400, { "error" => "bad" }))
    schedule!(seam.run)
    converge
    assert_equal "failed", seam.turn.reload.status

    retried = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: seam.run, task_key: "only", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    schedule!(seam.run)
    run_step!(seam.run)
    schedule!(seam.run)
    assert_equal "completed", seam.run.reload.status
    assert_equal "failed", seam.variant.reload.status, "the reopen job has not run"

    assert_equal 1, converge.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_equal "Mock: the answer", seam.variant.reload.content_preview
    assert_equal 0, converge.value[:recorded], "the repaired pair leaves the frontier"
  end

  test "cancel before reopen convergence settles once without replacing a newer candidate" do
    seam = seam!
    hold!(seam.run)
    converge
    Runs::Transition.run(seam.run, status: "canceling")
    Runs::Transition.run(seam.run, status: "canceled", completed_at: Time.current)
    assert_equal 1, converge.value[:recorded]
    assert_equal "canceled", seam.turn.reload.status
    assert_equal 0, converge.value[:recorded]

    newer = seam!
    hold!(newer.run)
    converge
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: newer.turn.public_id,
      entries: [{ "text" => "my answer" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?
    Runs::Transition.run(newer.run, status: "completed", completed_at: Time.current)
    assert_equal 0, converge.value[:recorded]
    assert_equal "failed", newer.variant.reload.status
    assert_equal edited.value.id, newer.turn.reload.active_variant_id
  end

  test "reopen is refused behind an edit: a person's answer stands" do
    seam = seam!
    hold!(seam.run)
    converge

    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: seam.turn.public_id,
      entries: [{ "text" => "my own answer" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?
    assert_equal "completed", seam.turn.reload.status

    Runs::Transition.run(seam.run, status: "running", attention_reason: nil)
    assert_equal 0, converge.value[:recorded]
    assert_equal "failed", seam.variant.reload.status, "the seam's variant is terminal and never rewritten"
    assert_equal "completed", seam.turn.reload.status
    assert_equal edited.value.id, seam.turn.active_variant_id
    assert_nil @conversation.reload.active_turn_id
  end

  test "the adjudication verbs read the seam under the lock: on the rendered variant a retry proceeds and reopens" do
    seam = seam!
    append!(seam.run, [model("only")])
    schedule!(seam.run)
    run_step!(seam.run, json_response(400, { "error" => "bad" }))
    run = schedule!(seam.run)
    assert_equal "needs_attention", run.status
    assert_equal "halt_failure", run.attention_reason
    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", seam.turn.reload.status
    assert_not_predicate run, :overridden?, "the loop's variant is what the turn shows"

    retried = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "only", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    assert_equal "running", run.reload.status
    assert_equal 1, converge.value[:recorded], "REOPEN: the person's retry runs the same turn again"
    assert_equal "running", seam.turn.reload.status
    assert_equal seam.turn.id, @conversation.reload.active_turn_id

    hold!(run)
    converge
    Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: seam.turn.public_id,
      entries: [{ "text" => "my own answer" }], acting_user: @human
    ))
    assert_predicate run.reload, :overridden?
    abandoned = Runs::Tasks::Abandon.call(Runs::Tasks::Abandon::Command.new(
      run: run, task_key: "only", acting_user: @human
    ))
    assert_equal :not_adjudicable, abandoned.outcome
    assert_nil seam.run.tasks.find_by!(node_key: "only").failure_resolution,
      "the refusal precedes the write"
    assert_equal "needs_attention", run.reload.status
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
    append!(seam.run, [model("only")])
    schedule!(seam.run)
    run_step!(seam.run, json_response(400, { "error" => "bad" }))
    run = schedule!(seam.run)
    assert_equal "halt_failure", run.attention_reason
    assert_equal 1, converge.value[:recorded]
    assert_equal "failed", seam.turn.reload.status
    settled_at = seam.variant.reload.updated_at

    clear_enqueued_jobs
    abandoned = nil
    # The commit wakes the converger (the loop's status changed) and no
    # scheduler: the ordering this pin stages is the queue's real one.
    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "run_id" => seam.run.id }]) do
      assert_no_enqueued_jobs(only: Runs::ScheduleJob) do
        abandoned = Runs::Tasks::Abandon.call(Runs::Tasks::Abandon::Command.new(
          run: run, task_key: "only", acting_user: @human
        ))
      end
    end
    assert_predicate abandoned, :accepted?
    run.reload
    assert_equal "needs_attention", run.status, "judged under the adjudication's own lock"
    assert_equal "deliverable_unresolved", run.attention_reason

    # The converger first, as the queue may run it.
    perform_enqueued_jobs(only: Conversations::Turns::ConvergeJob)
    assert_equal 0, converge.value[:recorded], "no arm matches: no running loop behind the failed tail"
    seam.variant.reload
    assert_equal "failed", seam.variant.status, "REOPEN never fired"
    assert_equal settled_at, seam.variant.updated_at, "the one settle stands; nothing re-settled the variant"
    assert_equal "failed", seam.turn.reload.status
    assert_equal 1, settled_items.length, "one settle narrated, on the halt"

    # Then the scheduler pass, level-triggered over a held loop: no change.
    schedule!(run)
    assert_equal "deliverable_unresolved", run.reload.attention_reason
    assert_equal settled_at, seam.variant.reload.updated_at

    # A word typed after the abandon is a post-settle word: it materializes
    # (never `run_held`) and the REPLACE arm stops the held loop.
    accept!(text: "carry on")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id),
      "the person's next word is the repair, not a row held behind the hold"
    assert_equal 2, @conversation.turns.count
    assert_empty @conversation.event_items.where(item_type: "input_blocked")
    assert_equal 1, converge.value[:recorded]
    run.reload
    assert_equal "canceling", run.status
    assert_equal "replaced", run.failure_reason
    assert_equal "failed", seam.variant.reload.status, "the terminal variant is never rewritten"
  end

  # ── REPLACE ─────────────────────────────────────────────────────────────

  test "a successor behind a held loop stops it replaced — the one site of the word" do
    seam = seam!
    hold!(seam.run)
    converge
    accept!(text: "never mind, start over")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id),
      "a post-settle word is the repair"
    assert_equal 2, @conversation.turns.count

    assert_equal 1, converge.value[:recorded]
    seam.run.reload
    assert_equal "canceling", seam.run.status
    assert_equal "replaced", seam.run.failure_reason
    assert_equal "failed", seam.variant.reload.status, "the terminal variant is never rewritten"
    assert_equal "failed", seam.turn.reload.status

    Runs::EvaluateQuiescence.call(seam.run)
    assert_equal "canceled", seam.run.reload.status
    assert_equal 0, converge.value[:recorded], "variant terminal, loop terminal: off the frontier"
    assert_equal "failed", seam.turn.reload.status
  end

  test "a loop a retry flipped running behind a successor is replaced, never reopened" do
    seam = seam!
    hold!(seam.run)
    converge
    accept!(text: "next")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    Runs::Transition.run(seam.run, status: "running", attention_reason: nil)

    assert_equal 1, converge.value[:recorded]
    assert_equal "canceling", seam.run.reload.status
    assert_equal "replaced", seam.run.failure_reason
    assert_equal "failed", seam.turn.reload.status, "no reopen flips a turn behind a successor"
    assert_nil @conversation.reload.active_turn_id
  end

  # ── The expired ask holds ───────────────────────────────────────────────

  test "a model's expired ask holds the loop, and the hold settles the turn with the ask named" do
    seam = seam!(run_status: "pending")
    append!(seam.run, [model("round1", "tools" => [Nexus::Tools::ASK])])
    Runs::Start.call(Runs::Start::Command.new(
      run: seam.run, acting_user: @human
    ))
    schedule!(seam.run)
    run_step!(seam.run, sse_success("asking", tool_calls: [
      { id: "call_c", name: "ask", arguments: { prompt: "Which database?" }.to_json },
    ]))
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [Runs::AskJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: seam.run.id)
    end
    ask = seam.run.tasks.where(type: Tasks::AwaitTask.sti_name).sole
    assert_equal "awaiting_input", ask.status
    assert_equal "halt", ask.on_failure, "a tokenless ask compiles halt whatever was authored"

    Task.where(id: ask.id).update_all(await_started_at: (Tasks::AwaitTask::MAX_HOLD + 1.second).ago)
    expired = Runs::Parks::Settle.call(node: ask.reload, timeout: true)
    assert_predicate expired, :applied?
    Runs::EvaluateQuiescence.call(seam.run.reload)
    Runs::EvaluateQuiescence.call(seam.run.reload)
    assert_equal "needs_attention", seam.run.reload.status
    assert_equal "halt_failure", seam.run.attention_reason

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
    settle = explain(*sources.find { |sql, _| sql.include?('FROM "variants"') })
    assert_match(/index_variants_settle_frontier/, settle)
    assert_no_match(/Seq Scan on variants/, settle)

    loop_sources = sources.select { |sql, _| sql.include?('FROM "runs"') }
    assert_equal 2, loop_sources.length
    loop_sources.each do |sql, binds|
      plan = explain(sql, binds)
      assert_match(/index_runs_stop_frontier/, plan)
      assert_no_match(/Seq Scan on runs|Sort|Filter:/, plan)
    end
  end

  private

    def seed_settled_history!(count:)
      now = Time.current
      actor = Speakers::Resolve.member(account: @account, user: @human)
      history = Conversation.create!(workspace: @workspace, creating_user: @human)
      turn_ids = Turn.insert_all!(Array.new(count) do |position|
        { account_id: @account.id, conversation_id: history.id, position: position,
          kind: "direct_reply", role: "assistant", status: "completed",
          speaker_id: actor.id, control_owner_user_id: @human.id,
          answering_user_id: history.answering_user_id,
          created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      variant_ids = Variant.insert_all!(turn_ids.map do |turn_id|
        { account_id: @account.id, turn_id: turn_id, position: 0,
          status: "completed", source: "run", created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      Run.insert_all!(variant_ids.map do |variant_id|
        { account_id: @account.id, workspace_id: @workspace.id, creating_user_id: @human.id,
          status: "completed", variant_id: variant_id, approval_mode: "bypass",
          created_at: now, updated_at: now }
      end)
      ApplicationRecord.lease_connection.execute(
        "ANALYZE turns, variants, runs"
      )
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds).join("\n")
    end
end
