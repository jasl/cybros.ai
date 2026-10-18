require "test_helper"

# The external rendezvous, end to end: the token is a second factor and
# never a credential of its own, the DEADLINE beats a late answer, and the
# sweep's SQL frontier is advisory — the Ruby clamp under the lock decides.
require_relative "../../test_helpers/awaits_test_helper"

class Runs::AwaitsTest < ActiveJob::TestCase
  include AwaitsTestHelper

  test "a parked await resolves, releases its dependents, and records its answer" do
    run = seed(await("gate"), model("after", "prompt" => "go on"))
    start!(run)
    gate = node(run, "gate")
    assert_equal "dispatched", gate.status
    assert_not_nil gate.await_started_at
    assert_equal "queued", node(run, "after").status

    assert_predicate resolve!(gate), :applied?

    gate.reload
    assert_equal "completed", gate.status
    assert_equal "the answer", gate.content_bodies.find_by!(role: "output").effective_text
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal "running", node(run, "after").status
  end

  test "the token is a second factor: a wrong one refuses and changes nothing" do
    run = seed(await("gate"))
    start!(run)
    gate = node(run, "gate")

    result = Runs::Parks::Settle.call(
      node: gate, claim_token: SecureRandom.uuid, content: "forged"
    )
    assert_equal :stale_claim, result.outcome
    assert_equal "dispatched", gate.reload.status
    assert_equal 0, gate.content_bodies.where(role: "output").count, "the ask's own question is its only body"
  end

  test "an undispatched await refuses: its token exists before its turn does" do
    run = seed(model("first"), await("gate"))
    start!(run)
    gate = node(run, "gate")
    assert_equal "queued", gate.status

    assert_equal :task_not_running, resolve!(gate).outcome,
      "completing here would release successors out of graph order"
  end

  test "a failed outcome escalates through the task's own policy" do
    run = seed(await("gate", "on_failure" => "propagate"), model("after"))
    start!(run)

    assert_predicate resolve!(node(run, "gate"), outcome: "failed"), :applied?

    assert_equal "failed", node(run, "gate").status
    assert_equal "await_failed", node(run, "gate").error_key
    assert_equal "skipped", node(run, "after").status
  end

  test "THE DEADLINE WINS: a late answer settles timed_out and its content is discarded" do
    run = seed(await("gate", "timeout_ms" => 60_000))
    start!(run)
    gate = node(run, "gate")
    gate.update_columns(await_started_at: 10.minutes.ago)

    result = resolve!(gate)
    assert_predicate result, :applied?

    gate.reload
    assert_equal "timed_out", gate.status
    assert_equal "await_timeout", gate.error_key
    assert_equal 0, gate.content_bodies.where(role: "output").count,
      "a late answer does not quietly succeed — its content is discarded"
  end

  test "a sweep that scanned before a re-arm writes nothing" do
    run = seed(await("gate", "timeout_ms" => 60_000))
    start!(run)
    gate = node(run, "gate")

    # The sweep's own arm, on a park that is NOT overdue: the Ruby recheck
    # under the lock is the arbiter, not the SQL selection that found it.
    result = Runs::Parks::Settle.call(node: gate, timeout: true)
    assert_equal :idle, result.outcome
    assert_equal "dispatched", gate.reload.status
  end

  test "the sweep expires an overdue park and reports a cursor" do
    run = seed(await("gate", "timeout_ms" => 1_000))
    start!(run)
    gate = node(run, "gate")
    gate.update_columns(await_started_at: 1.hour.ago)

    result = Runs::Parks::TimeoutSweep.call
    assert_equal 1, result[:expired]
    assert_equal gate.id, result.cursor
    assert_not result.more?
    assert_equal "timed_out", gate.reload.status
  end

  # THE EXPIRY RULE, one row per arm: never claimed → `timed_out` whatever the profile (nothing
  # started); claimed and replayable (read_only/pure, or intrinsic idempotency) → `timed_out`;
  # claimed and anything else → `uncertain`, with the two sentences the model and an adjudicator
  # read. A kernel row (`running` in one of our own jobs, never claimed) is the first arm too — even
  # one whose profile is a non-idempotent write. The client door refuses a kernel NAME on an
  # authored step, so the kernel row takes the mirror test's shape: a write profile moved to
  # `running` past the machine.
  test "the sweep settles a claimed tool park by its frozen profile" do
    read = seed(tool("r", "read_file"))
    write = seed(tool("w", "bash"))
    untaken = seed(tool("n", "bash"))
    kernel = seed(tool("m", "bash"))
    [read, write, untaken, kernel].each { |run| start!(run) }
    %w[r w].zip([read, write]).each do |key, run|
      assert_predicate Executors::Claim.call(Executors::Claim::Command.new(
        run: run, task_key: key, executor: suite_runner
      )), :accepted?
    end
    assert_nil node(untaken, "n").claimed_at
    Task.where(id: node(kernel, "m").id).update_all(status: "running")
    assert_not_predicate node(kernel, "m"), :replayable?, "the frozen profile is a write with no idempotency"
    assert_nil node(kernel, "m").claimed_at
    rows = [node(read, "r"), node(write, "w"), node(untaken, "n"), node(kernel, "m")]
    Task.where(id: rows.map(&:id)).update_all(await_started_at: 2.hours.ago)

    assert_equal 4, Runs::Parks::TimeoutSweep.call[:expired]

    assert_equal %w[timed_out tool_timeout], node(read, "r").values_at(:status, :error_key),
      "claimed, read-only: a re-run is harmless, so a plain timeout"
    assert_equal %w[uncertain tool_uncertain], node(write, "w").values_at(:status, :error_key),
      "claimed, write, no idempotency: the effect may have escaped"
    assert_equal Runs::Parks::Settle::UNCERTAIN_DETAIL, node(write, "w").error_detail
    assert_equal %w[timed_out tool_timeout], node(untaken, "n").values_at(:status, :error_key),
      "never claimed: nothing started, regardless of profile"
    assert_equal %w[timed_out tool_timeout], node(kernel, "m").values_at(:status, :error_key),
      "a kernel row is never claimed: the first arm, not the profile, decides"
  end

  # The predicate on the registry's own documents: an intrinsic write
  # (memory_write, a whole-document replace) is replayable; memory_edit
  # (find-and-replace, idempotency none) is not; a read is; nothing is.
  test "replayable? reads kind or intrinsic idempotency, and nothing else" do
    registry = Nexus::ToolRegistry
    assert registry.replayable?(registry.effect_profile_for("memory_read"))
    assert registry.replayable?(registry.effect_profile_for("memory_write"))
    assert_not registry.replayable?(registry.effect_profile_for("memory_edit"))
    assert registry.replayable?("kind" => "pure", "idempotency" => "none")
    assert registry.replayable?("kind" => "write", "idempotency" => "intrinsic")
    assert_not registry.replayable?("kind" => "write", "idempotency" => "keyed")
    assert_not registry.replayable?(nil)
    assert_not registry.replayable?("not a document")
  end

  # A profile-less claimed row cannot be admitted by a valid executor announcement, but the reading is pinned: absent means write-capable, never replayable.
  test "a claimed row with no frozen profile reads non-replayable" do
    run = seed(tool("r", "read_file"))
    start!(run)
    assert_predicate Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: "r", executor: suite_runner
    )), :accepted?
    row = node(run, "r")
    assert_predicate row, :replayable?
    row.update_columns(effect_profile: nil, await_started_at: 2.hours.ago)
    assert_not_predicate row.reload, :replayable?

    assert_equal 1, Runs::Parks::TimeoutSweep.call[:expired]
    assert_equal "uncertain", row.reload.status
  end

  test "the sweep's SQL and its Ruby agree on MEMBERSHIP, for both parked kinds" do
    # Drives the SHIPPED FRONTIER_SQL, not a hand-copy of it: the earlier
    # version restated the expression in the test, so the two could have
    # drifted with the pin still green (the recorded near-miss lesson).
    run = seed(parallel(await("gate"), tool("tool", "probe")), model("after"))
    start!(run)
    gate = node(run, "gate")
    tool = node(run, "tool")
    Task.where(id: tool.id).update_all(
      status: "running", await_started_at: Time.current
    )

    timeouts = [1_000, 3_600_000, 25.hours.in_milliseconds, 7.days.in_milliseconds, 500]
    ages = [0.seconds, 90.minutes, 25.hours, 3.days]

    # The tool arm's three sources: authored, else the announced timeout frozen on the row, else the
    # kernel default — every branch of the COALESCE driven, so the twin cannot drift on one of them.
    tool_configurations = ->(timeout_ms) {
      {
        "authored" => { timeout_ms: timeout_ms, effect_profile: nil },
        "announced" => { timeout_ms: nil, effect_profile: { "timeout_ms" => timeout_ms } },
      }
    }
    check = ->(timeout_ms, age, label) {
      armed = age.ago
      # Re-arm rather than expire: this pin is about MEMBERSHIP, and
      # settling a row would take it off the frontier for every later
      # row in the matrix.
      Task.where(id: [gate.id, tool.id])
        .update_all(await_started_at: armed, status: "running")
      selected = frontier_ids
      [gate, tool].each do |park|
        park.reload
        assert_equal park.deadline_passed?, selected.include?(park.id),
          "#{park.task_kind} #{label} timeout=#{timeout_ms} age=#{age.inspect}: " \
          "the SQL frontier and the locked recheck disagree — the sweep would " \
          "select rows the recheck refuses, or miss rows forever"
      end
    }

    timeouts.each do |timeout_ms|
      Task.where(id: gate.id).update_all(await_timeout_ms: timeout_ms)
      tool_configurations.call(timeout_ms).each do |label, columns|
        Task.where(id: tool.id).update_all(columns)
        ages.each { |age| check.call(timeout_ms, age, label) }
      end
    end

    Task.where(id: tool.id).update_all(timeout_ms: nil, effect_profile: nil)
    ages.each { |age| check.call(nil, age, "default") }

    # THE HELD ARM: a row resting for its approver is on the ask's 24 h clock whatever its authored
    # or announced RUN clock says — the SQL twin's first arm, and Parked's. Membership at MAX_HOLD ±
    # 1 s.
    held_ages = ages + [Tasks::AwaitTask::MAX_HOLD - 1.second, Tasks::AwaitTask::MAX_HOLD + 1.second]
    Task.where(id: gate.id).update_all(await_started_at: 1.minute.ago, status: "running")
    [{ timeout_ms: 1_000, effect_profile: nil }, { timeout_ms: nil, effect_profile: { "timeout_ms" => 500 } }].each do |columns|
      held_ages.each do |age|
        Task.where(id: tool.id).update_all(
          columns.merge(status: "needs_approval", started_at: nil, await_started_at: age.ago)
        )
        tool.reload
        assert_equal Tasks::AwaitTask::MAX_HOLD_MS, tool.effective_timeout_ms,
          "a run clock of #{columns.inspect} must not shorten the hold"
        assert_equal tool.deadline_passed?, frontier_ids.include?(tool.id),
          "held #{columns.inspect} age=#{age.inspect}: the SQL frontier and the locked recheck disagree"
        assert_equal age > Tasks::AwaitTask::MAX_HOLD, frontier_ids.include?(tool.id),
          "held age=#{age.inspect}: on the frontier iff older than MAX_HOLD"
      end
    end
  end


  # The ask's address is WRITTEN at start and listed in a later step: an agent's loop carries its
  # address on the row, a Human's standalone loop carries nobody — the person's door only.
  test "a tokenless ask on an agent-created loop is addressed to the agent application, on a Human's to nobody" do
    agent = users(:agent)
    asking = model("round1", "tools" => [Nexus::Tools::ASK])

    on_agent = seed(asking, creating_user: agent)
    Runs::Start.call(Runs::Start::Command.new(run: on_agent, acting_user: agent))
    asked = ask_through_the_model!(on_agent)
    assert_equal "awaiting_input", asked.status
    assert_nil asked.resolution_token
    assert_equal Executor.address_for(agent).id, asked.addressed_executor_id
    assert_equal "agent_application", asked.addressed_role

    on_human = seed(asking)
    Runs::Start.call(Runs::Start::Command.new(run: on_human, acting_user: @human))
    asked = ask_through_the_model!(on_human)
    assert_equal "awaiting_input", asked.status
    assert_nil asked.addressed_executor_id
    assert_nil asked.addressed_role
  end

  # THE ASK IS AN INBOX ROW: listed for its addressee with its question, never claimed and never
  # committed there — one live address per profile, the row a notice that a person is waited on, and
  # the executor door refusing it by kind on both verbs. The member `resolution` door answers it for
  # a person, and the second answer is `idle`.
  test "an addressed ask is listed on its addressee's inbox with its question, never claimable, and answered on the member door" do
    agent = users(:agent)
    address = Executor.address_for(agent)
    create_bound_credential(executor: address, name: "Lane transport")
    run = seed(model("round1", "tools" => [Nexus::Tools::ASK]), creating_user: agent)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: agent))
    asked = ask_through_the_model!(run)

    row = Executors::Inbox.call(executor: address).tasks.sole
    assert_equal "ask", row.fetch(:kind)
    assert_equal "which?", row.fetch(:prompt), "the question a person answers rides the row"
    assert_equal asked.node_key, row.fetch(:task_key)
    assert_equal false, row.fetch(:claimed)
    assert_not_nil row.fetch(:deadline_at), "the ask parks on its own clock"
    assert_equal({ role: "agent_application", executor_public_id: address.public_id }, row.fetch(:addressed_to))
    refute row.key?(:tool_name), "an ask names no tool"
    refute row.key?(:tool_input)

    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: asked.node_key, executor: address
    ))
    assert_equal :not_claimable_kind, claimed.outcome

    committed = executor_commit(run, asked.node_key, address, content: "Postgres")
    assert_equal :not_claimable_kind, committed.outcome, "the commit door gives the claim door's word"
    assert_equal "awaiting_input", asked.reload.status, "the executor plane settles no ask"

    assert_predicate Runs::Parks::Settle.call(node: asked, content: "Postgres"), :applied?,
      "the person's door answers the row"
    asked.reload
    assert_equal "completed", asked.status
    assert_equal "Postgres", asked.content_bodies.find_by!(role: "output").effective_text
    assert_equal [], Executors::Inbox.call(executor: address).tasks, "answered, the row leaves the inbox"
    Runs::EvaluateQuiescence.call(run.reload)
    assert_nil run.reload.attention_reason, "the announcement clears with the answer"

    assert_equal :idle, Runs::Parks::Settle.call(node: asked.reload, content: "MySQL").outcome,
      "write-once: the second answer is idle"
    assert_equal "Postgres", asked.reload.content_bodies.find_by!(role: "output").effective_text
  end

  test "a Human-created standalone loop's ask lists in no inbox and resolves by standing" do
    address = Executor.address_for(users(:agent))
    run = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    asked = ask_through_the_model!(run)

    assert_equal [], Executors::Inbox.call(executor: address).tasks,
      "addressed to nobody, the row is nobody's inbox row — the person's door only"
    assert_equal :not_addressed_here, executor_commit(run, asked.node_key, address, content: "x").outcome
    assert_equal "awaiting_input", asked.reload.status

    assert_predicate Runs::Parks::Settle.call(node: asked, content: "Postgres"), :applied?
    assert_equal "completed", asked.reload.status
  end

  # A client-authored await was handed its token in a receipt: a party the
  # kernel does not address holds the proof, so it is never a row.
  test "a tokened await is never a row" do
    address = Executor.address_for(users(:agent))
    run = seed(ask("gate"), creating_user: users(:agent))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: users(:agent)))
    Runs::ScheduleReady.call(run_id: run.id)
    gate = node(run, "gate")
    assert_equal "dispatched", gate.status

    assert_equal [], Executors::Inbox.call(executor: address).tasks
    assert_equal :not_addressed_here, executor_commit(run, "gate", address, content: "x").outcome
    assert_predicate resolve!(gate), :applied?
  end



  test "an await parks at most 24 hours, each park on its own (Q2, 2026-09-05)" do
    run = seed(
      await("long", "timeout_ms" => 6.days.in_milliseconds),
      await("next", "timeout_ms" => 6.hours.in_milliseconds)
    )
    start!(run)
    long = node(run, "long")
    assert_equal Tasks::AwaitTask::MAX_HOLD_MS, long.effective_timeout_ms,
      "the authored week is kept as intent; the derived deadline is clamped per park"
    assert_equal 6.days.in_milliseconds, long.await_timeout_ms

    # The first park idled most of a day; the next is NOT tightened by it
    # — there is no budget the parks share, only the clamp each carries.
    long.update_columns(await_started_at: 23.5.hours.ago)
    assert_predicate resolve!(long), :applied?
    Runs::ScheduleReady.call(run_id: run.id)
    following = node(run, "next")
    assert_equal "dispatched", following.status
    assert_equal 6.hours.in_milliseconds, following.effective_timeout_ms,
      "a loop may park as many times as its work needs"
  end

  test "a refused answer leaves the park retryable" do
    run = seed(await("gate", "timeout_ms" => 6.hours.in_milliseconds))
    start!(run)
    gate = node(run, "gate")

    # Storage refusing is the LAST guard in the ladder; nothing above it
    # may already have been committed.
    refused_body = ContentBodies::Replace::Result.refused(:unsupported_text)
    result = ContentBodies::Replace.stub(:call, ->(**) { refused_body }) do
      Runs::Parks::Settle.call(
        node: gate, claim_token: gate.resolution_token, content: "unstorable"
      )
    end

    assert_equal :result_unstorable, result.outcome
    assert_equal "dispatched", gate.reload.status
    assert_predicate resolve!(gate), :applied?
  end

  test "a failed resolution keeps the words that explain it" do
    run = seed(await("gate", "on_failure" => "halt"))
    start!(run)
    gate = node(run, "gate")

    assert_predicate resolve!(gate, content: "vendor rejected: address unverifiable",
      outcome: "failed"), :applied?

    gate.reload
    assert_equal "failed", gate.status
    assert_equal "await_failed", gate.error_key
    assert_equal "vendor rejected: address unverifiable", gate.error_detail,
      "an adjudicator choosing retry vs abandon has nothing else to read"
    assert_equal "vendor rejected: address unverifiable",
      gate.content_bodies.find_by!(role: "output").effective_text
  end

  test "a mid-pause resolution is adjudicated against the frozen clock (§9b)" do
    run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(run)
    gate = node(run, "gate")

    # Pause at +30m; the answer arrives at +2h wall time — mid-pause,
    # past the UNSHIFTED deadline. The virtual clock stands at paused_at,
    # so the deadline has not passed and the answer is accepted.
    Task.where(id: gate.id).update_all(await_started_at: 2.hours.ago)
    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(
      run: run, acting_user: @human
    )), :accepted?
    run.reload.update_columns(paused_at: 90.minutes.ago)

    assert_predicate resolve!(node(run, "gate"), content: "approved"), :applied?
    gate.reload
    assert_equal "completed", gate.status,
      "DEADLINE WINS reads the virtual clock: frozen time cannot expire a park"
  end

  test "resume repays the pause debt; stop-from-paused repays it too (§9b)" do
    run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(run)
    gate = node(run, "gate")
    armed_at = 30.minutes.ago
    Task.where(id: gate.id).update_all(await_started_at: armed_at)

    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(
      run: run, acting_user: @human
    )), :accepted?
    run.reload.update_columns(paused_at: 3.days.ago)

    assert_predicate Runs::Resume.call(Runs::Resume::Command.new(
      run: run, acting_user: @human
    )), :accepted?
    gate.reload
    assert_in_delta 3.days.since(armed_at), gate.await_started_at, 5,
      "the clock base shifts forward by exactly the pause"
    assert_nil run.reload.paused_at

    # Stop-from-paused: pause again, then stop gracefully — the shift
    # happens in the same locked transaction the drain begins in, so the
    # swept `canceling` state sees only live time.
    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(
      run: run, acting_user: @human
    )), :accepted?
    run.reload.update_columns(paused_at: 1.day.ago)
    base_before = gate.reload.await_started_at
    assert_predicate Runs::Stop.call(Runs::Stop::Command.new(
      run: run, acting_user: @human, force: false
    )), :accepted?
    run.reload
    assert_equal "canceling", run.status
    assert_nil run.paused_at,
      "no canceling loop carries a paused_at"
    assert_in_delta 1.day.since(base_before), gate.reload.await_started_at, 5
    assert_equal "dispatched", gate.status,
      "graceful stop still waits for the rendezvous, on the repaid clock"
  end

  test "the sweep frontier excludes paused loops and keeps canceling swept (§9b)" do
    run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(run)
    gate = node(run, "gate")
    Task.where(id: gate.id).update_all(await_started_at: 2.hours.ago)

    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(
      run: run, acting_user: @human
    )), :accepted?
    result = Runs::Parks::TimeoutSweep.call
    assert_equal "dispatched", gate.reload.status,
      "a paused loop's park is not even a candidate"

    # Graceful stop re-exposes the clock (debt repaid: ~0 pause here) —
    # and a canceling loop IS swept: the deadline still ends a drain
    # nobody resolves.
    assert_predicate Runs::Stop.call(Runs::Stop::Command.new(
      run: run, acting_user: @human, force: false
    )), :accepted?
    Task.where(id: gate.id).update_all(await_started_at: 2.hours.ago)
    Runs::Parks::TimeoutSweep.call
    assert_equal "timed_out", gate.reload.status,
      "DEADLINE-WINS ends a graceful stop nobody answers (no-zombie)"
    Runs::EvaluateQuiescence.call(run.reload)
    assert_equal "canceled", run.reload.status
  end
end
