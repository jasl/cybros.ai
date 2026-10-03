require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class ModelWorkLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  # The owner row is the aggregate's serialization point for both first write
  # and replacement. Once held, the command can trust the body it finds and
  # proceed directly to the fragment set without relocking its own child.
  test "content body replacement descends owner then fragment" do
    account = accounts(:cybros)
    owner, = create_invocation(account: account)
    upload = create_content_upload(account: account)
    payload = { "text" => "lock-order-content" }
    initial = ContentBodies::Replace.call(
      owner: owner, role: "input", entries: [payload],
      uploads: [upload]
    )
    assert_predicate initial, :accepted?

    sequences = assert_ladder_order("content body replacement") do
      result = ContentBodies::Replace.call(
        owner: owner, role: "input", entries: [payload], uploads: []
      )
      assert_predicate result, :accepted?
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "one_shots"
    assert_not_includes seen, "content_bodies",
      "the owner lock serializes the role singleton and its replacement"
    assert_includes seen, "content_fragments"
    assert_not_includes seen, "content_uploads"
  end

  # A create-and-seal writer runs inside its caller's owner serialization and
  # therefore takes only the fragment locks itself.
  test "an invocation-owned create-and-seal body locks only fragments" do
    account = accounts(:cybros)
    _, invocation = create_invocation(account: account)

    sequences = assert_ladder_order("invocation-owned body") do
      result = ContentBodies::Replace.call(
        owner: invocation, role: "request",
        entries: Nexus::InputEntries.for("write me"), seal: true
      )
      assert_predicate result, :accepted?
    end

    seen = sequences.flatten.uniq
    assert_not_includes seen, "model_invocations",
      "create-and-seal trusts the caller's owner serialization"
    assert_includes seen, "content_fragments"
    # The body row is CREATED here rather than locked, which is the whole
    # reason the owner is the serialization point: two concurrent first-writes
    # for one (owner, role) would otherwise both find nothing and both insert.
    assert_not_includes seen, "content_bodies"
  end

  # The create command is the first flow that spans the authority rows and the
  # content substrate in one transaction, so it is the one that would discover
  # a wrong answer between those two halves of the ladder.
  test "one shot creation descends workspace user owner then fragment" do
    upload = create_content_upload(account: accounts(:cybros))
    command = OneShots::Create::Command.new(
      workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation", submitted: DevModelLane.submission_for("text_generation"),
      configuration: {},
      # Media rides the ordered part grammar, which is the only place a text-generation upload has a
      # position.
      input: [{ "role" => "user", "parts" => [
        { "type" => "text", "text" => "guarded prompt" },
        { "type" => "upload", "upload_public_id" => upload.public_id },
      ] }],
      upload_public_ids: [upload.public_id],
      billing_subject: nil, idempotency_key: SecureRandom.uuid
    )

    sequences = assert_ladder_order("one shot create") do
      result = OneShots::Create.call(command: command, port: DevModelLane.port)
      assert_predicate result, :created?
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "workspaces"
    assert_includes seen, "users"
    assert_not_includes seen, "one_shots",
      "a newly inserted aggregate has no existing row to lock"
    assert_includes seen, "content_fragments"
    assert_includes seen, "content_uploads",
      "the door pins the resolved uploads inside its lock section (kernel S7)"
    # A first body is inserted, not locked. The owner serialization above it is
    # what makes that safe, and the replacement test beside this one proves the
    # same owner remains the serialization point for later writes.
    assert_not_includes seen, "content_bodies"
  end

  # Provider start serializes competing hosts on the parent Invocation row.
  # Stage 3 removed the Attempt's own `lock!` —
  # two starts for one attempt necessarily contend on that attempt's
  # invocation row first, so the second lock kept nobody out and only added a
  # rung to the ladder. What the claim actually needed there was a `reload`,
  # to see a concurrent writer's committed state.
  test "the provider start claim takes the parent invocation and nothing below it" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    _, invocation = create_invocation(account: account, status: "running")
    profile = DevModelLane.profile_for_invocation(invocation)
    attempt = ModelInvocationAttempt.create!(
      account: account, model_invocation: invocation, ordinal: 1,
      admission_shape: "admitted_free", deadline_at: 10.minutes.from_now
    )
    sequences = assert_ladder_order("provider start claim") do
      assert_predicate ModelInvocations::ProviderStart.call(
        attempt: attempt, host: "model_runner",
        base_url: ModelCatalog.provider_base_url(invocation.provider_id), profile: profile
      ), :started?
    end

    assert_includes sequences, %w[model_invocations],
      "the parent lock is the arbiter, and it is the only one"
    assert sequences.none? { _1.include?("model_invocation_attempts") },
      "a second lock on the row already covered by the parent's is a rung, not a guard"
  end

  # Terminal apply is the first flow that composes the invocation lock with
  # the content-body descent AND the attempt write. Its explicit lock is the
  # parent's alone — the attempt is rechecked by reload and written under
  # that lock, the Stage 3 conclusion applied consistently — so the captured
  # stream must show the invocation before the content locks and no explicit
  # attempt lock at all.
  test "terminal apply descends invocation then content, with no attempt lock" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    _, invocation = create_invocation(account: account, input: "apply me")
    assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length
    attempt = invocation.attempts.sole
    profile = DevModelLane.profile_for_invocation(invocation)
    start = ModelInvocations::ProviderStart.call(
      attempt: attempt, host: "solid_queue",
      base_url: ModelCatalog.provider_base_url(invocation.provider_id), profile: profile
    )
    assert_predicate start, :started?
    outcome = ModelInvocations::Dispatch::Result.new(
      outcome: ModelInvocations::Dispatch::SENT,
      result: SimpleInference::Responses::Result.new(
        output_text: "guarded", output_items: [], tool_calls: [], usage: nil,
        finish_reason: "completed", finish_detail: nil,
        provider_response: nil, provider_format: "responses"
      ),
      error: nil,
      timing: ModelInvocations::Dispatch::Timing.new(
        started_monotonic: 0.0, first_token_monotonic: nil, finished_monotonic: 0.1
      ),
      profile: profile,
      request_id: nil
    )

    sequences = assert_ladder_order("terminal apply") do
      result = ModelInvocations::ApplyResult.call(attempt: attempt, outcome: outcome)
      assert_predicate result, :applied?
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "model_invocations"
    assert_not_includes seen, "model_invocation_attempts",
      "the attempt is rechecked by reload and written under the parent lock, never locked itself"
  end

  # The caller owns the principal and Invocation locks; CancelUnstarted
  # reloads the child under that parent arbiter rather than locking it again.
  test "the unstarted cancel descends users then invocation without a child relock" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    Accounts::ConfigureCostUnit.call(account: account, cost_unit: "USD")
    account.reload # the configure writes past the instance (update_all); the rows below carry this one
    human = users(:member)
    _, invocation = create_invocation(
      account: account, creator: human, model: DevModelLane::PRICED_TEXT_MODEL
    )
    quote = ModelInvocations::AdmissionCandidate.call(invocation: invocation)
    attempt = ApplicationRecord.transaction do
      PrincipalLocks.descend(human)
      invocation.lock!
      ModelInvocations::AdmitUsage.call(
        invocation: invocation, quote: quote, consumer: human, payer: human, ordinal: 1
      ).attempt
    end

    sequences = assert_ladder_order("unstarted cancel") do
      result = ApplicationRecord.transaction do
        PrincipalLocks.descend(human)
        invocation.lock!
        ModelInvocations::CancelUnstarted.call(attempt: attempt, terminal_status: "failed")
      end
      assert_predicate result, :terminalized?
    end

    assert_includes sequences, %w[users model_invocations]
    assert_not_includes sequences.flatten, "model_invocation_attempts"
  end

  # ADMISSION is the pass that creates every Attempt, and it was the one
  # model-plane writer this guard never drove. Its row lock is a
  # `FOR UPDATE SKIP LOCKED` prefilter, which is exactly the shape that can
  # slip above the principals without anyone noticing: it reads like a query,
  # not like a lock.
  test "admission descends users before the invocation" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    Accounts::ConfigureCostUnit.call(account: account, cost_unit: "USD")
    account.reload # the configure writes past the instance (update_all); the rows below carry this one
    human = users(:member)
    _, invocation = create_invocation(
      account: account, creator: human, model: DevModelLane::PRICED_TEXT_MODEL,
      input: "say hi"
    )
    sequences = assert_ladder_order("admission") do
      assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length
    end

    # This pins that the principals come before the Invocation, which is the
    # half a SKIP LOCKED prefilter can silently invert.
    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[users model_invocations]
  end

  # The events converger holds the AGGREGATE first — every event INSERT's RI
  # check takes FOR KEY SHARE on one_shots, and Drain walks the same pair in
  # this order, so an invocation-first converger was an ABBA (the item-4
  # review's catch) — then the invocation, then the cursor's own row lock at
  # the ladder's last rank. Driven so a reorder fails here instead of
  # deadlocking against the drain on reap day.
  test "the events converger descends aggregate, invocation, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    one_shot, invocation = create_invocation(account: account, creator: human)
    ModelInvocation.where(id: invocation.id).update_all(status: "failed", failure_reason_key: "probe")

    sequences = assert_ladder_order("events converger") do
      assert_equal 1, OneShots::ConvergeTerminalEvents.call[:recorded]
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[one_shots model_invocations one_shot_event_cursors]
  end

  # A DECLINED call's record may switch the run to its creator's declared
  # fallback, and the switch re-reads Create's gates under Create's own
  # authority locks — so they come first, ahead of the aggregate the record
  # always holds: workspace, the agent creator, its steward, then the
  # aggregate, the declined call, and the cursor. Driven so the second
  # execution's mint never takes a rank out of order.
  test "the events converger's switch descends workspace, users, aggregate, invocation, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    agent = users(:agent)
    agent.update_columns(fallback_model: "dev/mock-unmetered")
    one_shot, invocation = create_invocation(account: account, creator: agent, input: "guarded prompt")
    ModelInvocation.where(id: invocation.id).update_all(status: "completed", finish_quality: "refused",
      terminal_at: Time.current)

    sequences = assert_ladder_order("events converger switch") do
      assert_equal 1, OneShots::ConvergeTerminalEvents.call(invocation_id: invocation.id)[:recorded]
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[workspaces users one_shots model_invocations one_shot_event_cursors]
    assert_equal 2, ModelInvocation.where(one_shot_id: one_shot.id).count, "the flow minted the fallback"
  end

  # The creator's cancel holds the aggregate — the lock the converger needs
  # before it can switch — then cuts the invocations and settles a declined
  # one on the spot with the cursor at the last rank. Driven with a declined
  # call left unrecorded, so the settle's descent is on the ladder too.
  test "the creator's cancel descends aggregate, invocation, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    one_shot, invocation = create_invocation(account: account, creator: users(:agent))
    ModelInvocation.where(id: invocation.id).update_all(status: "completed", finish_quality: "refused",
      terminal_at: Time.current)

    sequences = assert_ladder_order("one shot cancel") { OneShots::Cancel.call(one_shot: one_shot) }

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[one_shots model_invocations one_shot_event_cursors]
    assert_not_nil invocation.reload.terminal_event_recorded_at, "the flow settled the refusal"
  end

  # A streamed delta uses the same owner-first event path, but its running
  # gate also locks the Invocation so an authority cut and a delta have one
  # first winner. Keep that new lock on the reviewed ladder instead of
  # relying on the converger's adjacent-but-different flow.
  test "the stream sink descends aggregate, invocation, cursor" do
    account = accounts(:cybros)
    one_shot, invocation = create_invocation(account: account, status: "running")
    attempt = ModelInvocationAttempt.create!(
      account: account, model_invocation: invocation, ordinal: 1,
      admission_shape: "admitted_free", deadline_at: 10.minutes.from_now,
      provider_started_at: Time.current, status: "running", settlement_state: "pending",
      consumer_public_id: users(:member).public_id, payer_public_id: users(:member).public_id
    )
    sink = OneShotEvents::StreamSink.new(attempt: attempt, flush_interval_ms: 0)

    sequences = assert_ladder_order("stream sink") do
      sink.on_event(
        invocation,
        SimpleInference::Responses::Events::TextDelta.new(delta: "guarded")
      )
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[one_shots model_invocations one_shot_event_cursors]
    assert_equal "guarded", one_shot.one_shot_event_items.sole.payload.fetch("text")
  end

  # The settle batch is the ladder head's owner and its one driven flow: the
  # receipt frontier FOR UPDATE SKIP LOCKED, then every discovered payer
  # through the shared helper, then the payer's usable budget. This is the
  # flow the item-3 review caught locking a table the ladder had never
  # ranked; it is driven here so a second locker of usage_records, or a
  # reorder inside the batch, fails the guard instead of deadlocking in
  # production.
  test "the settle batch descends receipts payers budget" do
    account = accounts(:cybros)
    Accounts::ConfigureCostUnit.call(account: account, cost_unit: "USD")
    account.reload # the configure writes past the instance (update_all); the rows below carry this one
    human = users(:member)
    UsageBudgets::Open.call(
      actor: users(:owner), target: human, starts_at: 1.day.ago,
      amount: BigDecimal("10"), operation_key: "guard-settle-open"
    )
    UsageRecord.create!(
      account: account, idempotency_key: "guard-settle:1",
      model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
      consumer_user_public_id: human.public_id, payer_user_public_id: human.public_id,
      provider_id: "dev", catalog_model_ref: "dev/mock-priced", wire_model_id: "mock-priced",
      workload: "text_generation", purpose: "one_shot_attempt",
      service_class: "interactive", admission_shape: "priced", status: "succeeded",
      recorded_at: Time.current, cost_unit: "USD", cost_amount: BigDecimal("0.25")
    )

    sequences = assert_ladder_order("settle spend") do
      assert_equal 1, UsageRecords::SettleSpend.call[:charged]
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[usage_records users usage_budgets]
  end

  # Recovery uses the same Invocation arbiter as start/apply. It needs no
  # principal lock and does not lock the child a second time.
  test "the deadline sweep locks only the invocation arbiter" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    Accounts::ConfigureCostUnit.call(account: account, cost_unit: "USD")
    account.reload # the configure writes past the instance (update_all); the rows below carry this one
    human = users(:member)
    _, invocation = create_invocation(
      account: account, creator: human, model: DevModelLane::PRICED_TEXT_MODEL
    )
    quote = ModelInvocations::AdmissionCandidate.call(invocation: invocation)
    attempt = ApplicationRecord.transaction do
      PrincipalLocks.descend(human)
      invocation.lock!
      invocation.update!(status: "running")
      ModelInvocations::AdmitUsage.call(
        invocation: invocation, quote: quote, consumer: human, payer: human, ordinal: 1
      ).attempt
    end
    ModelInvocationAttempt.where(id: attempt.id).update_all(deadline_at: 1.minute.ago)

    sequences = assert_ladder_order("deadline sweep") do
      assert_equal 1, ModelInvocations::DeadlineSweep.call[:timed_out]
    end

    assert_includes sequences, %w[model_invocations]
    assert_not_includes sequences.flatten, "model_invocation_attempts"
  end

  # The tombstone command locks the aggregate and then reads its derived
  # status, so it takes `one_shots` and must be ranked against every flow that
  # descends from the authority rows into the same aggregate.
  test "the one shot tombstone locks the aggregate before reading its status" do
    account = accounts(:cybros)
    one_shot, invocation = create_invocation(account: account)
    ModelInvocation.where(id: invocation.id).update_all(status: "completed")

    sequences = assert_ladder_order("one shot tombstone") do
      assert_predicate OneShots::Tombstone.call(one_shot: one_shot), :accepted?
    end

    assert_includes sequences.flatten.uniq, "one_shots"
  end

  # The budget writers are the first physical flows on the users → usage_budgets edge: open rides
  # the User locks alone (no budget row exists to lock), adjust and revoke descend user then budget.
  test "budget open adjust and revoke keep the user before budget order" do
    Accounts::ConfigureCostUnit.call(account: accounts(:cybros), cost_unit: "USD")

    open_sequences = assert_ladder_order("budget open") do
      result = UsageBudgets::Open.call(
        actor: users(:owner), target: users(:owner), starts_at: Time.current,
        amount: BigDecimal("100"), operation_key: "guard-open"
      )
      assert_predicate result, :opened?
    end
    assert_includes open_sequences.flatten.uniq, "users"

    budget = UsageBudget.sole
    adjust_sequences = assert_ladder_order("budget adjust") do
      result = UsageBudgets::Adjust.call(
        actor: users(:owner), budget: budget, kind: :credit,
        amount: BigDecimal("5"), operation_key: "guard-adjust"
      )
      assert_predicate result, :adjusted?
    end
    seen = adjust_sequences.flatten.uniq
    assert_includes seen, "users"
    assert_includes seen, "usage_budgets"

    revoke_sequences = assert_ladder_order("budget revoke") do
      result = UsageBudgets::Revoke.call(
        actor: users(:owner), budget: budget, operation_key: "guard-revoke"
      )
      assert_predicate result, :revoked?
    end
    assert_includes revoke_sequences.flatten.uniq, "usage_budgets"
  end
end
