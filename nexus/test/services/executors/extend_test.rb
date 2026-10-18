require "test_helper"

# THE CLAIMANT'S EXTEND (review 2026-09-08, change 8 — 「对，是延期」: an
# extension, not a lease). One clock, no lease, no heartbeat — and a
# claimant at work may move its own deadline: bounded by the tool's
# announced park (or the kernel's hour), narrated so a watcher sees the
# runner ask for more time, refused to anyone but the current claimant.
# The extension moves the ONE clock the claim and the handoff re-arm, so
# the sweep's SQL twin follows without a second derivation.
class Executors::ExtendTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, **over) = super(key, "read_file", "input" => { "path" => key }, **over)

  def start!(run)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    clear_enqueued_jobs
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
  end

  def claim!(run, key, executor: suite_runner)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: key, executor: executor
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def extend(run, key, claim_token:, timeout_ms:, executor: suite_runner)
    Executors::Extend.call(Executors::Extend::Command.new(
      run: run, task_key: key, executor: executor,
      claim_token: claim_token, timeout_ms: timeout_ms
    ))
  end

  def node(run, key) = run.tasks.find_by!(node_key: key)

  def items(run, type)
    run.event_items.where(item_type: type).order(:sequence).map(&:payload)
  end

  # The sweep's SQL frontier at an instant, without expiring anything.
  def frontier_ids(at) = Runs::Parks::TimeoutSweep.new.send(:frontier, at).map(&:id)

  test "the claimant moves the one clock: the deadline is now plus the extension, and the sweep's twin agrees at ±1 s" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")
    before = node(run, "alpha").deadline_at

    result = extend(run, "alpha", claim_token: token, timeout_ms: 20.minutes.in_milliseconds)

    assert_predicate result, :accepted?, result.outcome.inspect
    row = node(run, "alpha")
    assert_in_delta 20.minutes.from_now.to_f, row.deadline_at.to_f, 5, "the new deadline is the extension from now"
    assert_operator row.deadline_at, :>, before
    assert_equal result.value.deadline_at, row.deadline_at
    assert_equal "dispatched", row.status
    assert_equal token, row.claim_token, "an extension rotates nothing: the claim stands"
    assert_equal "read_file", row.tool_name
    # THE SQL TWIN FOLLOWS THE REWRITTEN CLOCK: one second before the new
    # deadline the sweep lists nothing, one second after it lists the row.
    assert_not_includes frontier_ids(row.deadline_at - 1.second), row.id
    assert_includes frontier_ids(row.deadline_at + 1.second), row.id
  end

  test "the extension is narrated, so a watcher sees the runner ask for more time" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")

    extend(run, "alpha", claim_token: token, timeout_ms: 5.minutes.in_milliseconds)

    narrated = items(run, "task_deadline_extended")
    assert_equal 1, narrated.length
    item = narrated.sole
    assert_equal "alpha", item.fetch("task_key")
    assert_equal node(run, "alpha").deadline_at.iso8601, item.fetch("deadline_at")
    assert_equal suite_runner.public_id, item.fetch("by")
    assert_equal 5.minutes.in_milliseconds, item.fetch("timeout_ms")
    assert_includes EventItem::ITEM_TYPES, "task_deadline_extended"
  end

  test "no count limit: a live claimant extends again and again" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")

    3.times do |round|
      result = extend(run, "alpha", claim_token: token, timeout_ms: (round + 1).minutes.in_milliseconds)
      assert_predicate result, :accepted?, "extension #{round + 1}: #{result.outcome}"
    end
    assert_in_delta 3.minutes.from_now.to_f, node(run, "alpha").deadline_at.to_f, 5
    assert_equal 3, items(run, "task_deadline_extended").length
  end

  # Bounded by the tool's ANNOUNCED park when it announced one, else by
  # the kernel's hour: a runner may keep working, never park a row for a week.
  test "each extension is bounded by the announced timeout, or the kernel's hour" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")

    assert_equal :extension_too_long,
      extend(run, "alpha", claim_token: token, timeout_ms: 61.minutes.in_milliseconds).outcome
    assert_predicate extend(run, "alpha", claim_token: token, timeout_ms: 60.minutes.in_milliseconds), :accepted?

    profile = node(run, "alpha").effect_profile.merge("timeout_ms" => 30_000)
    Task.where(id: node(run, "alpha").id).update_all(effect_profile: profile)
    assert_equal :extension_too_long,
      extend(run, "alpha", claim_token: token, timeout_ms: 30_001).outcome,
      "the announced park is the bound once the tool announced one"
    assert_predicate extend(run, "alpha", claim_token: token, timeout_ms: 30_000), :accepted?
    assert_in_delta 30.seconds.from_now.to_f, node(run, "alpha").deadline_at.to_f, 5
    assert_equal Executors::Extend::MAX_EXTENSION_MS, 1.hour.in_milliseconds
  end

  test "only the current claimant: a wrong token, another executor, or a stale token is not_claimant" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")
    before = node(run, "alpha").deadline_at

    assert_equal :not_claimant, extend(run, "alpha", claim_token: "nope", timeout_ms: 60_000).outcome
    assert_equal :not_claimant, extend(run, "alpha", claim_token: nil, timeout_ms: 60_000).outcome
    assert_equal :not_claimant,
      extend(run, "alpha", claim_token: token, timeout_ms: 60_000, executor: executors(:address)).outcome,
      "an executor that is not the claimant is refused whatever token it carries"
    assert_equal before, node(run, "alpha").reload.deadline_at, "a refusal moves nothing"
    assert_empty items(run, "task_deadline_extended")
  end

  test "a row that is not a claimed dispatched park is not_extendable" do
    run = seed(tool("alpha"), tool("beta"))
    start!(run)
    assert_equal "dispatched", node(run, "alpha").status
    assert_equal :not_extendable,
      extend(run, "alpha", claim_token: "x", timeout_ms: 60_000).outcome,
      "unclaimed: nobody holds it, so nobody extends it"
    assert_equal :not_extendable,
      extend(run, "beta", claim_token: "x", timeout_ms: 60_000).outcome, "queued: not a park"

    token = claim!(run, "alpha")
    settled = Runs::Parks::Settle.call(node: node(run, "alpha"), claim_token: token,
      content: "done", outcome: "completed")
    assert_predicate settled, :applied?
    assert_equal :not_extendable,
      extend(run, "alpha", claim_token: token, timeout_ms: 60_000).outcome, "settled: nothing to extend"
    assert_equal :not_found, extend(run, "nope", claim_token: token, timeout_ms: 60_000).outcome
  end

  test "a paused claim renews its virtual window and projects the existing pause debt" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")
    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(
      run: run, acting_user: @human
    )), :accepted?

    travel 2.hours do
      assert_predicate extend(run, "alpha", claim_token: token, timeout_ms: 60_000), :accepted?
      current = node(run, "alpha")
      assert_in_delta run.reload.paused_at.to_f + 60, current.deadline_at.to_f, 0.01
      assert_in_delta 60.seconds.from_now.to_f, current.wall_deadline_at.to_f, 0.01
      assert_predicate Runs::Resume.call(Runs::Resume::Command.new(
        run: run, acting_user: @human
      )), :accepted?
      assert_in_delta 60.seconds.from_now.to_f, current.reload.deadline_at.to_f, 0.01
      assert_equal token, current.claim_token
    end
  end

  # A late commit after expiry stays an expiry: the extension is the
  # claimant's way to PREVENT it, never a way to resurrect a settled row.
  test "an extended park still expires at its deadline, and a commit after that is the expiry's" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")
    assert_predicate extend(run, "alpha", claim_token: token, timeout_ms: 60_000), :accepted?

    Task.where(id: node(run, "alpha").id).update_all(await_started_at: 2.hours.ago)
    assert_equal 1, Runs::Parks::TimeoutSweep.call[:expired]
    assert_equal %w[timed_out tool_timeout], node(run, "alpha").values_at(:status, :error_key)

    late = Runs::Parks::Settle.call(node: node(run, "alpha"), claim_token: token,
      content: "late", outcome: "completed")
    assert_equal :idle, late.outcome, "the answer arrived after the question stopped mattering"
    assert_equal :not_extendable, extend(run, "alpha", claim_token: token, timeout_ms: 60_000).outcome
  end
end
