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

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def claim!(agent_loop, key, executor: suite_runner)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: key, executor: executor
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def extend(agent_loop, key, claim_token:, timeout_ms:, executor: suite_runner)
    Executors::Extend.call(Executors::Extend::Command.new(
      agent_loop: agent_loop, task_key: key, executor: executor,
      claim_token: claim_token, timeout_ms: timeout_ms
    ))
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def items(agent_loop, type)
    agent_loop.conversation_event_items.where(item_type: type).order(:sequence).map(&:payload)
  end

  # The sweep's SQL frontier at an instant, without expiring anything.
  def frontier_ids(at) = AgentLoops::Parks::TimeoutSweep.new.send(:frontier, at).map(&:id)

  test "the claimant moves the one clock: the deadline is now plus the extension, and the sweep's twin agrees at ±1 s" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    token = claim!(agent_loop, "alpha")
    before = node(agent_loop, "alpha").deadline_at

    result = extend(agent_loop, "alpha", claim_token: token, timeout_ms: 20.minutes.in_milliseconds)

    assert_predicate result, :accepted?, result.outcome.inspect
    row = node(agent_loop, "alpha")
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
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    token = claim!(agent_loop, "alpha")

    extend(agent_loop, "alpha", claim_token: token, timeout_ms: 5.minutes.in_milliseconds)

    narrated = items(agent_loop, "task_deadline_extended")
    assert_equal 1, narrated.length
    item = narrated.sole
    assert_equal "alpha", item.fetch("task_key")
    assert_equal node(agent_loop, "alpha").deadline_at.iso8601, item.fetch("deadline_at")
    assert_equal suite_runner.public_id, item.fetch("by")
    assert_equal 5.minutes.in_milliseconds, item.fetch("timeout_ms")
    assert_includes ConversationEventItem::ITEM_TYPES, "task_deadline_extended"
  end

  test "no count limit: a live claimant extends again and again" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    token = claim!(agent_loop, "alpha")

    3.times do |round|
      result = extend(agent_loop, "alpha", claim_token: token, timeout_ms: (round + 1).minutes.in_milliseconds)
      assert_predicate result, :accepted?, "extension #{round + 1}: #{result.outcome}"
    end
    assert_in_delta 3.minutes.from_now.to_f, node(agent_loop, "alpha").deadline_at.to_f, 5
    assert_equal 3, items(agent_loop, "task_deadline_extended").length
  end

  # Bounded by the tool's ANNOUNCED park when it announced one, else by
  # the kernel's hour: a runner may keep working, never park a row for a week.
  test "each extension is bounded by the announced timeout, or the kernel's hour" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    token = claim!(agent_loop, "alpha")

    assert_equal :extension_too_long,
      extend(agent_loop, "alpha", claim_token: token, timeout_ms: 61.minutes.in_milliseconds).outcome
    assert_predicate extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60.minutes.in_milliseconds), :accepted?

    profile = node(agent_loop, "alpha").effect_profile.merge("timeout_ms" => 30_000)
    AgentLoopNode.where(id: node(agent_loop, "alpha").id).update_all(effect_profile: profile)
    assert_equal :extension_too_long,
      extend(agent_loop, "alpha", claim_token: token, timeout_ms: 30_001).outcome,
      "the announced park is the bound once the tool announced one"
    assert_predicate extend(agent_loop, "alpha", claim_token: token, timeout_ms: 30_000), :accepted?
    assert_in_delta 30.seconds.from_now.to_f, node(agent_loop, "alpha").deadline_at.to_f, 5
    assert_equal Executors::Extend::MAX_EXTENSION_MS, 1.hour.in_milliseconds
  end

  test "only the current claimant: a wrong token, another executor, or a stale token is not_claimant" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    token = claim!(agent_loop, "alpha")
    before = node(agent_loop, "alpha").deadline_at

    assert_equal :not_claimant, extend(agent_loop, "alpha", claim_token: "nope", timeout_ms: 60_000).outcome
    assert_equal :not_claimant, extend(agent_loop, "alpha", claim_token: nil, timeout_ms: 60_000).outcome
    assert_equal :not_claimant,
      extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60_000, executor: task_executors(:address)).outcome,
      "an executor that is not the claimant is refused whatever token it carries"
    assert_equal before, node(agent_loop, "alpha").reload.deadline_at, "a refusal moves nothing"
    assert_empty items(agent_loop, "task_deadline_extended")
  end

  test "a row that is not a claimed dispatched park is not_extendable" do
    agent_loop = seed(tool("alpha"), tool("beta"))
    start!(agent_loop)
    assert_equal "dispatched", node(agent_loop, "alpha").status
    assert_equal :not_extendable,
      extend(agent_loop, "alpha", claim_token: "x", timeout_ms: 60_000).outcome,
      "unclaimed: nobody holds it, so nobody extends it"
    assert_equal :not_extendable,
      extend(agent_loop, "beta", claim_token: "x", timeout_ms: 60_000).outcome, "queued: not a park"

    token = claim!(agent_loop, "alpha")
    settled = AgentLoops::Parks::Settle.call(node: node(agent_loop, "alpha"), claim_token: token,
      content: "done", outcome: "completed")
    assert_predicate settled, :applied?
    assert_equal :not_extendable,
      extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60_000).outcome, "settled: nothing to extend"
    assert_equal :not_found, extend(agent_loop, "nope", claim_token: token, timeout_ms: 60_000).outcome
  end

  test "a paused loop's clocks stand still, so nothing is extended on it" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    token = claim!(agent_loop, "alpha")
    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?

    assert_equal :not_extendable, extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60_000).outcome
  end

  # A late commit after expiry stays an expiry: the extension is the
  # claimant's way to PREVENT it, never a way to resurrect a settled row.
  test "an extended park still expires at its deadline, and a commit after that is the expiry's" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    token = claim!(agent_loop, "alpha")
    assert_predicate extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60_000), :accepted?

    AgentLoopNode.where(id: node(agent_loop, "alpha").id).update_all(await_started_at: 2.hours.ago)
    assert_equal 1, AgentLoops::Parks::TimeoutSweep.call[:expired]
    assert_equal %w[timed_out tool_timeout], node(agent_loop, "alpha").values_at(:status, :error_key)

    late = AgentLoops::Parks::Settle.call(node: node(agent_loop, "alpha"), claim_token: token,
      content: "late", outcome: "completed")
    assert_equal :idle, late.outcome, "the answer arrived after the question stopped mattering"
    assert_equal :not_extendable, extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60_000).outcome
  end
end
