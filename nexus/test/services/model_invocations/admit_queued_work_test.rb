require "test_helper"

# THE ADMISSION PASS — the caller the four admission seams were built for.
#
# Before it, nothing in the tree could create an Attempt at all. So the first
# test is the whole point: queued work becomes running work with a prepared
# attempt and a woken host.
class ModelInvocations::AdmitQueuedWorkTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "queued work becomes running work with one prepared attempt" do
    invocation = queued_invocation

    result = ModelInvocations::AdmitQueuedWork.call

    assert_equal 1, result.admitted.length
    invocation.reload
    assert_equal "running", invocation.status
    attempt = invocation.attempts.sole
    assert_equal "prepared", attempt.status
    assert_equal 1, attempt.ordinal
    assert_not_nil attempt.deadline_at, "admission stamps the deadline it starts the clock on"
    assert_enqueued_with(job: ModelInvocations::RunJob)
  end

  test "custom provider capacity uses the same effective declaration as admission" do
    result = ModelProviders::SetDefinition.call(account: @account, provider_id: "local", expected_lock_version: nil,
      definition: { "base_url" => "http://127.0.0.1:11434", "api_format" => "openai_compatible_chat",
        "credentials" => "none", "concurrency_limit" => 1 })
    result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "local", model_ref: "local/model",
      model: {}, expected_lock_version: result.policy.lock_version, validate_definition: true)
    ModelProviders::EnableLane.call(account: @account, provider_id: "local", expected_lock_version: result.policy.lock_version)
    invocations = Array.new(2) { queued_invocation(model: "local/model") }

    result = ModelInvocations::AdmitQueuedWork.call(batch_size: 2)

    assert_equal 1, result.admitted.length
    assert_equal %w[queued running], invocations.map { |invocation| invocation.reload.status }.sort
    assert_equal "unmetered", result.admitted.sole.invocation.attempts.sole.admission_shape
  end

  # ADMISSION DOES NOT COMPILE THE REQUEST. It used to run the whole prepare
  # seam here — downloading and resizing every image — and seal a second body
  # with a digest over it, before the claim. Stage 3 deleted that body: the
  # predecessor stored the input once and lowered at send, and so does this.
  test "admission writes no body and does no media IO" do
    invocation = queued_invocation

    ModelInvocations::AdmitQueuedWork.call

    assert_empty invocation.reload.content_bodies,
      "the invocation owns no compiled request; the input it lowers belongs to the InferenceRequest"
  end

  # **VALIDITY BEFORE CAPACITY, and the order is not cosmetic.** The caps are read from the catalog
  # by provider id, and a provider that left it has no ceiling to read — the catalog raises rather
  # than inventing one, correctly. Asked in the wrong order that turned a lane's retirement into an
  # exception out of the whole pass, once a minute forever: nothing reaps a queued candidate, so the
  # scan re-offers the same poison row every pass. Checking validity first produces a typed terminal
  # refusal.
  test "a lane that left the catalog is refused, not raised" do
    invocation = queued_invocation
    # Around `attr_readonly`, which is the point: the column is immutable to
    # the application precisely because a lane retires UNDER a frozen row.
    ModelInvocation.where(id: invocation.id).update_all(provider_id: "retired_vendor")

    result = nil
    assert_nothing_raised { result = ModelInvocations::AdmitQueuedWork.call }

    assert_empty result.admitted
    invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "unknown_model", invocation.failure_reason_key
    assert_predicate invocation, :terminal?, "and it stops being offered"
  end

  test "missing Account cost unit admits the invocation without computed cost" do
    invocation = queued_invocation(model: DevModelLane::PRICED_TEXT_MODEL)

    ModelInvocations::AdmitQueuedWork.call

    assert_equal "running", invocation.reload.status
    assert_nil invocation.failure_reason_key
    assert_equal "unmetered", invocation.attempts.sole.admission_shape
  end

  # Disabling a provider after acceptance must produce an admission refusal, just as removing the
  # accepted model does. Admission reads current composed policy before considering capacity.
  test "a lane the operator switched off is refused at admission" do
    invocation = queued_invocation
    ModelProviders::DisableLane.call(
      account: @account, provider_id: "dev",
      expected_lock_version: ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
        .lock_version
    )

    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted

    invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "provider_disabled", invocation.failure_reason_key
  end

  # A full batch says nothing about the work behind it. Without this the
  # platform admitted one batch a minute however much capacity was free.
  test "a pass that fills its batch asks to be run again" do
    3.times { queued_invocation }

    result = ModelInvocations::AdmitQueuedWork.call(batch_size: 2)

    assert_equal 2, result.admitted.length
    assert_predicate result, :more?
    assert_not_predicate ModelInvocations::AdmitQueuedWork.call(batch_size: 2), :more?
  end

  # ADMISSION QUOTES FROM THE ACCOUNT'S OWN CATALOG — an overlay that removes
  # a model must be able to end queued work, and one that reprices it feeds
  # the settlement that reads the effective rates later.
  test "a per-account override reaches the quote, not just acceptance" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    @account.reload
    invocation = queued_invocation(model: DevModelLane::PRICED_TEXT_MODEL)
    ref = "#{invocation.provider_id}/#{invocation.model_ref}"
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    ModelProviders::RemoveModelOverride.call(
      account: @account, provider_id: "dev", model_ref: ref,
      expected_lock_version: policy.lock_version
    )

    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted

    invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "unknown_model", invocation.failure_reason_key,
      "the overlay-removed model is refused from the EFFECTIVE catalog"
  end

  # The only product back-edge to queued is a real started transient failure.
  # Admission does not need a second budget reader: ApplyResult already kept
  # the reachable row queued, and the latest terminal ordinal names the next.
  test "a transient retry is admitted with the next ordinal" do
    first = admitted_attempt
    invocation = first.model_invocation
    failure = json_response(
      503, { "error" => { "message" => "overloaded" } }, headers: { "retry-after" => "0" }
    )

    assert_predicate apply_via(first, failure), :requeued?
    second = ModelInvocations::AdmitQueuedWork.call.admitted
      .find { _1.invocation.id == invocation.id }

    assert_not_nil second
    assert_equal 2, second.attempt.ordinal
    assert_equal "running", invocation.reload.status
  end

  # AN UNMETERED LANE ADMITS WITH NO MONEY AT ALL — no unit configured, no
  # budget open, no reservation row, no hold. That is the whole point of the
  # declaration: billing is auxiliary, and a lane whose cost this platform
  # does not compute must not be blocked by a cost plane that has nothing to
  # say about it. The trade is that no budget can cap it either; what still
  # bounds it is the capacity brakes, the attempt budget, and the deadline.
  test "an unmetered lane admits with no unit, no budget, and no reservation" do
    invocation = queued_invocation(model: DevModelLane::UNMETERED_TEXT_MODEL)
    assert_nil @account.reload.cost_unit
    assert_equal 0, UsageBudget.count

    assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length

    attempt = invocation.reload.attempts.sole
    assert_equal "running", invocation.status
    assert_equal "unmetered", attempt.admission_shape
  end

  # And it is not free. A receipt may say known-free work cost nothing; it may
  # not say that about work whose cost was never computed.
  test "unmetered is a different shape from admitted_free" do
    unmetered = queued_invocation(model: DevModelLane::UNMETERED_TEXT_MODEL)
    free = queued_invocation

    ModelInvocations::AdmitQueuedWork.call

    assert_equal "unmetered", unmetered.reload.attempts.sole.admission_shape
    assert_equal "admitted_free", free.reload.attempts.sole.admission_shape
  end

  # Admission reads the eventually settled budget head without reserving funds. It refuses new
  # priced work when the budget is exhausted; bounded overspend from concurrent admission and
  # settlement lag is accepted.
  test "an exhausted budget is a terminal refusal for priced work" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    open_budget(credited: "1", debited: "1")
    invocation = queued_invocation(model: DevModelLane::PRICED_TEXT_MODEL)

    result = ModelInvocations::AdmitQueuedWork.call

    assert_empty result.admitted
    invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "budget_exhausted", invocation.failure_reason_key
  end

  test "a budget with headroom admits priced work" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    open_budget(credited: "1", debited: "0.5")
    invocation = queued_invocation(model: DevModelLane::PRICED_TEXT_MODEL)

    assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length
    assert_equal "running", invocation.reload.status
  end

  test "no budget means no cap: priced lanes run uncapped until one caps them" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    assert_equal 0, UsageBudget.count
    invocation = queued_invocation(model: DevModelLane::PRICED_TEXT_MODEL)

    assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length
    assert_equal "running", invocation.reload.status
  end

  # A budget ROW that exists but covers no usable window must be as good as
  # no budget — `.first` instead of the usable_at? filter turned an old
  # exhausted window into a terminal refusal of funded work in the review's
  # mutant, and terminal is forever.
  test "an expired exhausted window does not veto a live funded one" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    open_budget(credited: "1", debited: "1", starts_at: 2.days.ago, expires_at: 1.day.ago)
    open_budget(credited: "1", debited: "0")
    invocation = queued_invocation(model: DevModelLane::PRICED_TEXT_MODEL)

    instantiated = 0
    subscriber = lambda do |*, payload|
      instantiated += payload.fetch(:record_count) if payload.fetch(:class_name) == "UsageBudget"
    end
    admitted = ActiveSupport::Notifications.subscribed(
      subscriber, "instantiation.active_record"
    ) do
      ModelInvocations::AdmitQueuedWork.call.admitted
    end

    assert_equal 1, admitted.length
    assert_operator instantiated, :<=, 1,
      "the database filters historical windows before admission materializes a budget head"
    assert_equal "running", invocation.reload.status
  end

  test "an exhausted window that already expired caps nothing" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    open_budget(credited: "1", debited: "1", starts_at: 2.days.ago, expires_at: 1.day.ago)
    invocation = queued_invocation(model: DevModelLane::PRICED_TEXT_MODEL)

    assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length,
      "no USABLE budget means no cap, whatever old windows say"
    assert_equal "running", invocation.reload.status
  end

  test "an exhausted budget does not touch free work" do
    open_budget(credited: "1", debited: "1")
    invocation = queued_invocation

    assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length
    assert_equal "admitted_free", invocation.reload.attempts.sole.admission_shape
  end

  # Invocation admission does not reject from an estimated prompt count. Sending performs request
  # construction, and a provider may still refuse its actual input limit; this test distinguishes
  # admission from provider execution.
  test "a prompt over the declared token window is admitted, not refused here" do
    invocation = queued_invocation(input: "x " * 9_000)

    result = ModelInvocations::AdmitQueuedWork.call

    assert_equal 1, result.admitted.length
    assert_equal "running", invocation.reload.status
  end

  test "a disabled lane refusal leaves no attempt and no running invocation" do
    invocation = queued_invocation(model: DevModelLane::PRICED_TEXT_MODEL)
    ModelProviderConfig.find_by!(account: @account, provider_id: "dev").update!(enabled: false)

    result = ModelInvocations::AdmitQueuedWork.call

    assert_empty result.admitted
    assert_equal 1, result.rejected
    assert_equal "failed", invocation.reload.status
    assert_equal "provider_disabled", invocation.failure_reason_key
    assert_empty invocation.attempts
  end

  # Capacity is a brake, not a refusal: work that does not fit stays queued
  # and is offered again on the next pass.
  test "work that exceeds a cap stays queued for the next pass" do
    fill_workload_capacity
    invocation = queued_invocation

    result = ModelInvocations::AdmitQueuedWork.call

    assert_empty result.admitted
    assert_equal "queued", invocation.reload.status, "a full provider defers work, it does not fail it"
  end

  # The per-payer brake counts by the key it caps by: an Agent's running work
  # fills its steward's slots, so the steward's own queued work waits behind
  # it (review gap 20, 2026-09-05).
  test "an agent's running work brakes its steward's queued work" do
    limit = ModelInvocations::RunningCapacity::USER_ACTIVE_LIMIT
    agent = create_agent_member(steward: @human)
    with_provider_headroom(limit * 2) do
      limit.times { queued_invocation(creator: agent).update!(status: "running") }
      invocation = queued_invocation

      result = ModelInvocations::AdmitQueuedWork.call

      assert_empty result.admitted
      assert_equal "queued", invocation.reload.status, "the steward is braked by its agent's work"
    end
  end

  # Fairness: one owner with a deep queue cannot take the whole batch.
  test "the pass round-robins across owners" do
    3.times { queued_invocation(creator: @human) }
    other = queued_invocation(creator: users(:owner))

    result = ModelInvocations::AdmitQueuedWork.call(batch_size: 2)

    admitted = result.admitted.map { |a| a.invocation.creating_user_id }
    assert_includes admitted, other.creating_user_id,
      "the second owner is served before the first owner's second candidate"
    assert_equal 2, admitted.length
  end

  # Priority is an IN-LANE tie break, never a global rank. Ranking by priority
  # first would hand the window to the loudest caller and make the per-owner
  # ranking decorative — so a high-priority latecomer does NOT jump ahead of
  # another owner's older work.
  test "priority does not reorder the scan across owners" do
    first = queued_invocation(creator: @human)
    loud = queued_invocation(creator: users(:owner))
    # Around `attr_readonly`: priority is fixed at create, and this stages the
    # row a caller who asked for the front of their own lane would have.
    ModelInvocation.where(id: loud.id).update_all(priority: 9)

    result = ModelInvocations::AdmitQueuedWork.call(batch_size: 1)

    assert_equal [first.id], result.admitted.map { |a| a.invocation.id },
      "FIFO across owners; priority only breaks ties inside one lane"
  end

  # A deferred candidate is not due yet, so the scan does not see it.
  test "work deferred to the future is not a candidate" do
    invocation = queued_invocation
    invocation.update!(next_admission_at: 1.hour.from_now)

    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted
    assert_equal "queued", invocation.reload.status
  end

  # ---- THE PROVIDER ADMISSION FLOOR (owner 2026-09-15, item 11) ----------
  #
  # A lane whose provider said "not before T" is not offered: its rows are
  # neither admitted nor rejected (a rejection consumes a disposition and
  # would let a floored row starve nobody and cost everybody), the other
  # lanes are untouched, and once the clock passes the rows re-enter in
  # arrival order — the anti-join reads the one clock the pass reads.

  def floor_lane(provider_id, until_at)
    ModelProviderRuntimeState.raise_floor(account_id: @account.id, provider_id: provider_id, until_at: until_at)
  end

  test "a floored lane's queued rows are neither admitted nor rejected" do
    rows = 3.times.map { queued_invocation }
    floor_lane("dev", DatabaseClock.now + 60)

    result = ModelInvocations::AdmitQueuedWork.call

    assert_empty result.admitted
    assert_equal 0, result.rejected, "a held row consumes no disposition"
    assert_equal %w[queued queued queued], rows.map { |row| row.reload.status }
    assert_empty ModelInvocationAttempt.where(model_invocation_id: rows.map(&:id)),
      "nothing was claimed under the floor"
  end

  test "a floor on another lane of the same account holds nothing here" do
    invocation = queued_invocation
    floor_lane("openrouter", DatabaseClock.now + 60)

    result = ModelInvocations::AdmitQueuedWork.call

    assert_equal [invocation.id], result.admitted.map { |a| a.invocation.id }
  end

  test "a floor at exactly now admits" do
    invocation = queued_invocation
    floor_lane("dev", DatabaseClock.now)

    result = ModelInvocations::AdmitQueuedWork.call

    assert_equal [invocation.id], result.admitted.map { |a| a.invocation.id },
      "strict: the requeue's own `..now` edge, so the wake scheduled AT the floor finds the rows"
  end

  test "once the floor passes the rows re-enter in arrival order" do
    rows = 3.times.map { queued_invocation }
    floor_lane("dev", DatabaseClock.now + 60)
    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted

    # The clock passing, staged: the row's time becomes the past.
    ModelProviderRuntimeState.where(account_id: @account.id, provider_id: "dev")
      .update_all(next_admission_at: DatabaseClock.now - 1)

    result = ModelInvocations::AdmitQueuedWork.call(batch_size: 2)

    assert_equal rows.first(2).map(&:id), result.admitted.map { |a| a.invocation.id },
      "the rows kept their place: arrival order, never a re-sort by the floor"
  end

  test "the floor costs the candidate read nothing: the one clock read and one statement" do
    3.times { queued_invocation }
    floor_lane("dev", DatabaseClock.now + 60)
    admitter = ModelInvocations::AdmitQueuedWork.new

    # `SELECT clock_timestamp()` and the window: what the read cost before
    # the floor, and what it costs with it — the anti-join rides inside.
    assert_queries_count(2, include_schema: false) { admitter.send(:candidates) }
    assert_queries_match(/NOT \(EXISTS/, count: 1) { admitter.send(:candidates) }
  end

  # The batch bound is a bound: a pass admits what it was asked for and leaves
  # the rest for the next one.
  test "a pass stops at its batch size" do
    3.times { queued_invocation }

    result = ModelInvocations::AdmitQueuedWork.call(batch_size: 2)

    assert_equal 2, result.admitted.length
    assert_equal 1, ModelInvocation.where(status: "queued").count
  end

  test "a pass enqueues every admitted attempt with one runner notification" do
    2.times { queued_invocation }
    notifications = 0

    result = ModelInvocations::Wake.stub(:notify_runner_after_commit, -> { notifications += 1 }) do
      ModelInvocations::AdmitQueuedWork.call(batch_size: 2)
    end

    assert_equal 2, result.admitted.length
    assert_equal 2, enqueued_jobs.count { _1["job_class"] == "ModelInvocations::RunJob" }
    assert_equal 1, notifications
  end

  test "a pass composes one effective catalog per account" do
    2.times { queued_invocation }
    original = ModelSelection::Resolver.method(:effective_catalog)
    calls = 0

    ModelSelection::Resolver.stub(:effective_catalog, ->(account, snapshot) {
      calls += 1
      original.call(account, snapshot)
    }) do
      assert_equal 2, ModelInvocations::AdmitQueuedWork.call(batch_size: 2).admitted.length
    end

    assert_equal 1, calls
  end

  # THE RANKING HAPPENS BEFORE THE LIMIT, and this is the test the in-memory
  # rotation class could not pass. It received a FIFO window and round-robined
  # within it, so an owner with more queued work than the window held owned
  # every slot in it and the ring degenerated to FIFO — the exact starvation
  # the class was named to prevent. The window function ranks each owner's
  # queue over the whole eligible set, so a later owner's first row outranks
  # an earlier owner's second no matter how deep the earlier queue is.
  test "a queue deeper than the scan window cannot starve a later owner" do
    3.times { queued_invocation(creator: @human) }
    other = queued_invocation(creator: users(:owner))

    admitted = stub_const(ModelInvocations::AdmitQueuedWork, :CANDIDATE_WINDOW, 2) do
      ModelInvocations::AdmitQueuedWork.call(batch_size: 2).admitted
    end

    assert_includes admitted.map { _1.invocation.id }, other.id,
      "the deep lane fills a FIFO window; ranking before the limit is what lets the other owner in"
  end

  # ...AND THE RANKED SET ITSELF IS BOUNDED (re-audit decision 1). Ranking
  # over the whole backlog is O(N log N) per pass, and the backlog grows
  # exactly when passes are densest (an outage requeues everything with
  # cooldowns, and every expiry wakes a pass). So fairness is over the oldest
  # FAIRNESS_WINDOW waiters, not over everyone — this test states the cost of
  # that choice rather than hiding it: a latecomer beyond the window waits for
  # a pass whose window reaches it.
  test "fairness runs over the source window, not the whole backlog" do
    2.times { queued_invocation(creator: @human) }
    latecomer = queued_invocation(creator: users(:owner))

    admitted = stub_const(ModelInvocations::AdmitQueuedWork, :FAIRNESS_WINDOW, 2) do
      ModelInvocations::AdmitQueuedWork.call(batch_size: 2).admitted
    end

    assert_not_includes admitted.map { _1.invocation.id }, latecomer.id,
      "outside the source window there is nothing to rank — the bound is real"
    assert_equal 2, admitted.length, "and the window's own rows still admit"
  end

  test "the ranked set carries its own limit, index-aligned on arrival order" do
    sql = ModelInvocations::AdmitQueuedWork.new.send(:due_queued_window).to_sql

    assert_includes sql, "LIMIT #{ModelInvocations::AdmitQueuedWork::FAIRNESS_WINDOW}"
    assert_includes sql, %(ORDER BY "model_invocations"."created_at" ASC),
      "the window rides index_model_invocations_on_queued_scan so the LIMIT stops the walk"
  end

  # Contention is not an error: another admitter holds the lock, so this pass
  # says so and lets the scheduled job cover the trigger.
  test "a contended advisory lock reports rather than blocks" do
    queued_invocation
    # A lambda that ignores the block, because Minitest's stub CALLS the block
    # when the stub value is not callable — stubbing a bare `false` would have
    # run the claim and then reported contention, which is the one outcome
    # this test exists to prove impossible.
    ModelInvocation.stub(:with_advisory_lock, ->(*, **) { false }) do
      result = ModelInvocations::AdmitQueuedWork.call

      assert_predicate result, :lock_contended?
      assert_empty result.admitted
    end
  end

  private

    def queued_invocation(model: nil, creator: nil, input: "say hi")
      selection = DevModelLane.selection(
        workload: "text_generation", account: @account, **(model ? { model: model } : {})
      )
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: creator || @human,
        workload: selection.workload
      )
      body = ContentBodies::Replace.call(
        owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for(input), seal: true
      )
      raise "input refused: #{body.refusal.inspect}" unless body.accepted?

      DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
    end

    def open_budget(credited:, debited:, starts_at: 1.minute.ago, expires_at: nil)
      UsageBudget.create!(
        account: @account, user: @human, user_public_id: @human.public_id,
        user_kind: @human.kind, starts_at: starts_at, expires_at: expires_at,
        credited_amount: BigDecimal(credited), debited_amount: BigDecimal(debited),
        last_entry_sequence: 0
      )
    end

    def fill_workload_capacity
      limit = ModelCatalog.provider_concurrency_limit("dev", workload: "text_generation")
      limit.times { queued_invocation.update!(status: "running") }
    end

    # Lifts the provider and workload caps so the per-payer brake is the one
    # measured; on the real dev lane the workload cap binds first.
    def with_provider_headroom(limit, &)
      ModelCatalog.stub(
        :provider_concurrency_limit,
        ->(_id, workload: nil, snapshot: ModelCatalog.current) { limit }, &
      )
    end
end
