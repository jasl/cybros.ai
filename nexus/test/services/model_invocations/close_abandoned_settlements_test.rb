require "test_helper"

# The late-evidence window closer (item-7 review round two): without it, a
# pending settlement whose writer died fences its aggregate out of
# reclamation forever. It closes ONLY evidence-dead pendings — terminal,
# past the window — and an overlapping real writer converges on one matching
# receipt and Attempt state.
class ModelInvocations::CloseAbandonedSettlementsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    selection = DevModelLane.selection(
      workload: "text_generation", account: @account
    )
    @one_shot = OneShot.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: selection.workload
    )
    @invocation = DevModelLane.create_invocation!(one_shot: @one_shot, selection: selection)
  end

  # THE MONEY HAS TO SURVIVE THE AGGREGATE, and for this one class it did not.
  # A started attempt whose wire outcome was never observed — an ordinary
  # deploy landing mid-stream is enough — earned no receipt at all, so closing
  # it flipped one column and left `usage_records` holding nothing. Then
  # reclamation deletes the Attempt, which the drain calls "the only durable
  # record that a provider was ever asked", and the fact that money may have
  # been spent leaves no trace anywhere. The receipt is what the teardown
  # deliberately spares; closure is the last moment it can be written.
  test "closing an evidence-dead pending writes the receipt that outlives the aggregate" do
    attempt = build_attempt(ordinal: 1, status: "timed_out", settlement_state: "pending",
      terminal_at: 8.days.ago)

    assert_equal 1, ModelInvocations::CloseAbandonedSettlements.call
    assert_equal "abandoned", attempt.reload.settlement_state

    receipt = UsageRecord.find_by(
      model_invocation_public_id: @invocation.public_id, attempt_ordinal: 1
    )
    assert_not_nil receipt, "the attempt is about to be deleted; this is what remains"
    assert_equal "abandoned", receipt.status,
      "not `failed` — failed asserts nothing was charged, and that is exactly what is unknown"
    assert_nil receipt.wire_model_id, "nothing observed the wire, so nothing may claim to name it"
    assert_nil receipt.cost_amount, "unknown cost is recorded as unknown, never as zero"
    assert_nil receipt.total_tokens
  end

  # And a receipt already written wins: the closer never overwrites evidence.
  test "an attempt that earned a real receipt is not reopened by the closer" do
    attempt = build_attempt(ordinal: 1, status: "timed_out", settlement_state: "pending",
      terminal_at: 8.days.ago)
    winner = UsageRecords::Record.call(
      attempt: attempt, outcome: nil, status: "discarded"
    )
    ModelInvocationAttempt.where(id: attempt.id).update_all(settlement_state: "pending")

    assert_equal 0, ModelInvocations::CloseAbandonedSettlements.call
    assert_equal "settled", attempt.reload.settlement_state
    assert_equal "discarded", winner.reload.status
    assert_equal 1, UsageRecord.where(
      account_id: @account.id,
      model_invocation_public_id: @invocation.public_id,
      attempt_ordinal: attempt.ordinal
    ).count
  end

  test "an admitted-free abandonment records an exact zero without an outcome" do
    attempt = build_attempt(
      ordinal: 1, status: "timed_out", settlement_state: "pending",
      terminal_at: 8.days.ago, admission_shape: "admitted_free"
    )

    assert_equal 1, ModelInvocations::CloseAbandonedSettlements.call

    receipt = UsageRecord.find_by!(
      account_id: @account.id,
      model_invocation_public_id: @invocation.public_id,
      attempt_ordinal: attempt.ordinal
    )
    assert_equal BigDecimal(0), receipt.cost_amount
    assert_nil receipt.cost_unit
    assert_equal "abandoned", attempt.reload.settlement_state
  end

  test "one invocation processes at most one configured source window" do
    attempts = 3.times.map do |index|
      build_attempt(
        ordinal: index + 1, status: "timed_out", settlement_state: "pending",
        terminal_at: 8.days.ago + index.seconds
      )
    end

    assert_equal 2,
      ModelInvocations::CloseAbandonedSettlements.new(batch_size: 2).call
    assert_equal %w[abandoned abandoned pending],
      attempts.map { |attempt| attempt.reload.settlement_state }

    assert_equal 1,
      ModelInvocations::CloseAbandonedSettlements.new(batch_size: 2).call
    assert_equal %w[abandoned abandoned abandoned],
      attempts.map { |attempt| attempt.reload.settlement_state }
  end

  test "one batch preloads immutable receipt context instead of querying per attempt" do
    invocations = [@invocation] + 2.times.map do
      one_shot = OneShot.create!(
        account: @account,
        workspace: workspaces(:shared),
        creating_user: users(:member),
        workload: "text_generation"
      )
      DevModelLane.create_invocation!(one_shot: one_shot)
    end
    invocations.each_with_index do |invocation, index|
      build_attempt(
        invocation: invocation,
        ordinal: 1,
        status: "timed_out",
        settlement_state: "pending",
        terminal_at: 8.days.ago + index.seconds
      )
    end
    reads = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      reads << sql if sql.start_with?("SELECT") && !payload[:cached]
    end

    begin
      assert_equal 3,
        ModelInvocations::CloseAbandonedSettlements.new(batch_size: 3).call
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, reads.count { |sql| sql.include?('FROM "one_shots"') }
    assert_equal 1, reads.count { |sql| sql.include?('FROM "workspaces"') }
    assert_equal 1, reads.count { |sql| sql.include?('FROM "accounts"') }
    assert_equal 3, reads.count { |sql| sql.include?("FOR UPDATE OF model_invocations") },
      "only the per-Invocation arbitration remains cardinality-dependent"
  end

  test "a receipt failure stays loud and leaves the candidate untouched" do
    attempt = build_attempt(
      ordinal: 1, status: "timed_out", settlement_state: "pending",
      terminal_at: 8.days.ago
    )
    failure = Class.new(StandardError)

    UsageRecords::Record.stub(:call, ->(**) { raise failure, "write failed" }) do
      assert_raises(failure) do
        ModelInvocations::CloseAbandonedSettlements.call
      end
    end

    assert_equal "pending", attempt.reload.settlement_state
    assert_not UsageRecord.exists?(
      account_id: @account.id,
      model_invocation_public_id: @invocation.public_id,
      attempt_ordinal: attempt.ordinal
    )
  end

  # THE ORDERED WINDOW MUST SURVIVE A POISONED HEAD. Raising at the first
  # unwritable row would put the same row at the front of every wake and fence
  # every aggregate behind it out of reclamation forever — so every healthy
  # row settles first, and only then does the original error fail the job.
  test "a poisoned head row does not fence the rows behind it" do
    poisoned = build_attempt(ordinal: 1, status: "timed_out", settlement_state: "pending",
      terminal_at: 9.days.ago)
    healthy = build_attempt(ordinal: 2, status: "timed_out", settlement_state: "pending",
      terminal_at: 8.days.ago)
    failure = Class.new(StandardError)
    real = UsageRecords::Record.method(:call)

    UsageRecords::Record.stub(:call, lambda { |attempt:, **rest|
      raise failure, "poisoned" if attempt.id == poisoned.id

      real.call(attempt: attempt, **rest)
    }) do
      assert_raises(failure) { ModelInvocations::CloseAbandonedSettlements.call }
    end

    assert_equal "pending", poisoned.reload.settlement_state, "retried next wake"
    assert_equal "abandoned", healthy.reload.settlement_state,
      "the fence behind the poisoned row still lifted"
  end

  test "the bounded stale source uses its partial frontier index at scale" do
    created_at = 10.days.ago.change(usec: 0)
    terminal_at = 8.days.ago.change(usec: 0)
    ModelInvocationAttempt.insert_all!(
      Array.new(8_000) do |index|
        {
          account_id: @account.id,
          model_invocation_id: @invocation.id,
          ordinal: index + 1,
          admission_shape: "priced",
          status: "timed_out",
          settlement_state: "pending",
          terminal_at: terminal_at,
          deadline_at: terminal_at,
          consumer_public_id: users(:member).public_id,
          payer_public_id: users(:member).public_id,
          created_at: created_at,
          updated_at: created_at,
        }
      end
    )
    ApplicationRecord.lease_connection.execute("ANALYZE model_invocation_attempts")

    source_scan = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA" || payload[:cached]

      if sql.start_with?('SELECT "model_invocation_attempts".*') &&
          sql.include?('"model_invocation_attempts"."settlement_state"')
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end

    receipt = UsageRecord.new(status: UsageRecord::ABANDONED)
    begin
      UsageRecords::Record.stub(:call, receipt) do
        assert_equal 0,
          ModelInvocations::CloseAbandonedSettlements.new(batch_size: 500).call
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert source_scan, "the public closer must execute its bounded source scan"
    plan = explain(*source_scan)
    assert_match(
      /Index(?: Only)? Scan using index_attempts_settlement_frontier/,
      plan
    )
    assert_match(/\ALimit\s/, plan)
    assert_no_match(/Seq Scan on model_invocation_attempts(?:\s|$)/, plan)
    assert_no_match(/Bitmap/, plan)
    assert_no_match(/Sort/, plan)
    assert_no_match(/Filter:/, plan)
  end

  test "closes only terminal pendings past the window, and the fence lifts" do
    stale = build_attempt(ordinal: 1, status: "timed_out", settlement_state: "pending",
      terminal_at: 8.days.ago)
    young = build_attempt(ordinal: 2, status: "timed_out", settlement_state: "pending",
      terminal_at: 6.days.ago)
    live = build_attempt(ordinal: 3, status: "running", settlement_state: "pending",
      terminal_at: nil)
    settled = build_attempt(ordinal: 4, status: "completed", settlement_state: "settled",
      terminal_at: 8.days.ago)

    closed = ModelInvocations::CloseAbandonedSettlements.call

    assert_equal 1, closed
    assert_equal "abandoned", stale.reload.settlement_state,
      "owed a receipt, the window closed with nothing observed"
    assert_equal "pending", young.reload.settlement_state,
      "a late answer may still land inside the window"
    assert_equal "pending", live.reload.settlement_state,
      "a live attempt's settlement is the receipt writer's business, never this sweep's"
    assert_equal "settled", settled.reload.settlement_state

    ModelInvocation.where(id: @invocation.id).update_all(status: "completed")
    ModelInvocationAttempt.where(id: [young.id, live.id]).delete_all
    OneShot.where(id: @one_shot.id).update_all(tombstoned_at: 31.days.ago)
    OneShots::Reap.call(batch: 10)
    assert_not OneShot.exists?(@one_shot.id),
      "abandoned is not pending: the closed window lifts the reclamation fence"
  end

  test "the closer is on the recurring schedule in every environment" do
    entry = recurring_schedule.fetch("close_abandoned_attempt_settlements")
    assert_equal ModelInvocations::CloseAbandonedSettlementsJob.name, entry.fetch("class")
    assert_equal "every hour at minute 50", entry.fetch("schedule")
    assert_equal recurring_schedule, recurring_schedule("development")
  end

  test "the window outlasts redelivery and undercuts reclamation age" do
    window = ModelInvocations::CloseAbandonedSettlements::LATE_EVIDENCE_WINDOW
    assert_operator window, :>=, 1.day, "generous against any queue redelivery"
    assert_operator window, :<, OneShot::RETENTION_PERIOD,
      "the fence must lift before the teardown ever looks"
  end

  private

    def build_attempt(ordinal:, status:, settlement_state:, terminal_at:,
                      admission_shape: "priced", invocation: @invocation)
      # Consumer and payer are stamped at admission, so an attempt that ever
      # STARTED carries both — and the receipt this closer writes needs them.
      ModelInvocationAttempt.create!(
        account: @account, model_invocation: invocation, ordinal: ordinal,
        admission_shape: admission_shape, deadline_at: 10.minutes.from_now,
        consumer_public_id: users(:member).public_id,
        payer_public_id: users(:member).public_id,
        status: status, settlement_state: settlement_state, terminal_at: terminal_at
      )
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds).join("\n")
    end
end
