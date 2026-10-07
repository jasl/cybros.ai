require "test_helper"

# The external rendezvous, end to end: the token is a second factor and
# never a credential of its own, the DEADLINE beats a late answer, and the
# sweep's SQL frontier is advisory — the Ruby clamp under the lock decides.
class AgentRuns::AwaitsTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def await(key, **over) = ask(key, **over)

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run.reload
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def resolve!(node, **over)
    AgentRuns::Parks::Settle.call(
      node: node, claim_token: node.resolution_token, content: "the answer", **over
    )
  end

  def declared(name)
    { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
  end

  def attempt_of(agent_run, key)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == node(agent_run, key).selected_model_invocation_id
    end
    raise "#{key} not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  # THE SEALED BYTES a tool result becomes: a round calls `read_file` once, the runner settles the
  # call with `result`, and the continuation's request is BUILT — the pairing's
  # `function_call_output` is what the model reads of that result, and this answers it beside the
  # settled call. Never `effective_text` alone: that would keep passing on the wrong bytes.
  def paired_output_after(**result)
    agent_run = seed(model("round1", "prompt" => "go", "tools" => [declared("read_file")]),
      model("m2", "prompt" => "then"))
    start!(agent_run)
    apply_via(attempt_of(agent_run, "round1"), sse_success("calling", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule_loop!(agent_run)
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read")
    assert_equal "dispatched", call.status

    assert_predicate AgentRuns::Parks::Settle.call(node: call, trusted: true, **result), :applied?
    schedule_loop!(agent_run)
    continuation = node(agent_run, "r1")
    assert_equal "running", continuation.status, "the model reads the result on the next round"
    build(attempt_of(agent_run, "r1"))
    item = round_request_entries(continuation).find { |payload| payload["type"] == "tool_result_item" }
    [call.reload, item.dig("payload", "output")]
  end

  test "a parked await resolves, releases its dependents, and records its answer" do
    agent_run = seed(await("gate"), model("after", "prompt" => "go on"))
    start!(agent_run)
    gate = node(agent_run, "gate")
    assert_equal "dispatched", gate.status
    assert_not_nil gate.await_started_at
    assert_equal "queued", node(agent_run, "after").status

    assert_predicate resolve!(gate), :applied?

    gate.reload
    assert_equal "completed", gate.status
    assert_equal "the answer", gate.content_bodies.find_by!(role: "output").effective_text
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal "running", node(agent_run, "after").status
  end

  test "the token is a second factor: a wrong one refuses and changes nothing" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    result = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: SecureRandom.uuid, content: "forged"
    )
    assert_equal :stale_claim, result.outcome
    assert_equal "dispatched", gate.reload.status
    assert_equal 0, gate.content_bodies.where(role: "output").count, "the ask's own question is its only body"
  end

  test "an undispatched await refuses: its token exists before its turn does" do
    agent_run = seed(model("first"), await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")
    assert_equal "queued", gate.status

    assert_equal :task_not_running, resolve!(gate).outcome,
      "completing here would release successors out of graph order"
  end

  test "a failed outcome escalates through the task's own policy" do
    agent_run = seed(await("gate", "on_failure" => "propagate"), model("after"))
    start!(agent_run)

    assert_predicate resolve!(node(agent_run, "gate"), outcome: "failed"), :applied?

    assert_equal "failed", node(agent_run, "gate").status
    assert_equal "await_failed", node(agent_run, "gate").error_key
    assert_equal "skipped", node(agent_run, "after").status
  end

  test "THE DEADLINE WINS: a late answer settles timed_out and its content is discarded" do
    agent_run = seed(await("gate", "timeout_ms" => 60_000))
    start!(agent_run)
    gate = node(agent_run, "gate")
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
    agent_run = seed(await("gate", "timeout_ms" => 60_000))
    start!(agent_run)
    gate = node(agent_run, "gate")

    # The sweep's own arm, on a park that is NOT overdue: the Ruby recheck
    # under the lock is the arbiter, not the SQL selection that found it.
    result = AgentRuns::Parks::Settle.call(node: gate, timeout: true)
    assert_equal :idle, result.outcome
    assert_equal "dispatched", gate.reload.status
  end

  test "the sweep expires an overdue park and reports a cursor" do
    agent_run = seed(await("gate", "timeout_ms" => 1_000))
    start!(agent_run)
    gate = node(agent_run, "gate")
    gate.update_columns(await_started_at: 1.hour.ago)

    result = AgentRuns::Parks::TimeoutSweep.call
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
    [read, write, untaken, kernel].each { |agent_run| start!(agent_run) }
    %w[r w].zip([read, write]).each do |key, agent_run|
      assert_predicate Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: agent_run, task_key: key, executor: suite_runner
      )), :accepted?
    end
    assert_nil node(untaken, "n").claimed_at
    AgentRunTask.where(id: node(kernel, "m").id).update_all(status: "running")
    assert_not_predicate node(kernel, "m"), :replayable?, "the frozen profile is a write with no idempotency"
    assert_nil node(kernel, "m").claimed_at
    rows = [node(read, "r"), node(write, "w"), node(untaken, "n"), node(kernel, "m")]
    AgentRunTask.where(id: rows.map(&:id)).update_all(await_started_at: 2.hours.ago)

    assert_equal 4, AgentRuns::Parks::TimeoutSweep.call[:expired]

    assert_equal %w[timed_out tool_timeout], node(read, "r").values_at(:status, :error_key),
      "claimed, read-only: a re-run is harmless, so a plain timeout"
    assert_equal %w[uncertain tool_uncertain], node(write, "w").values_at(:status, :error_key),
      "claimed, write, no idempotency: the effect may have escaped"
    assert_equal AgentRuns::Parks::Settle::UNCERTAIN_DETAIL, node(write, "w").error_detail
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
    agent_run = seed(tool("r", "read_file"))
    start!(agent_run)
    assert_predicate Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: "r", executor: suite_runner
    )), :accepted?
    row = node(agent_run, "r")
    assert_predicate row, :replayable?
    row.update_columns(effect_profile: nil, await_started_at: 2.hours.ago)
    assert_not_predicate row.reload, :replayable?

    assert_equal 1, AgentRuns::Parks::TimeoutSweep.call[:expired]
    assert_equal "uncertain", row.reload.status
  end

  test "the sweep's SQL and its Ruby agree on MEMBERSHIP, for both parked kinds" do
    # Drives the SHIPPED FRONTIER_SQL, not a hand-copy of it: the earlier
    # version restated the expression in the test, so the two could have
    # drifted with the pin still green (the recorded near-miss lesson).
    agent_run = seed(parallel(await("gate"), tool("tool", "probe")), model("after"))
    start!(agent_run)
    gate = node(agent_run, "gate")
    tool = node(agent_run, "tool")
    AgentRunTask.where(id: tool.id).update_all(
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
      AgentRunTask.where(id: [gate.id, tool.id])
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
      AgentRunTask.where(id: gate.id).update_all(await_timeout_ms: timeout_ms)
      tool_configurations.call(timeout_ms).each do |label, columns|
        AgentRunTask.where(id: tool.id).update_all(columns)
        ages.each { |age| check.call(timeout_ms, age, label) }
      end
    end

    AgentRunTask.where(id: tool.id).update_all(timeout_ms: nil, effect_profile: nil)
    ages.each { |age| check.call(nil, age, "default") }

    # THE HELD ARM: a row resting for its approver is on the ask's 24 h clock whatever its authored
    # or announced RUN clock says — the SQL twin's first arm, and Parked's. Membership at MAX_HOLD ±
    # 1 s.
    held_ages = ages + [AgentRunTasks::AwaitTask::MAX_HOLD - 1.second, AgentRunTasks::AwaitTask::MAX_HOLD + 1.second]
    AgentRunTask.where(id: gate.id).update_all(await_started_at: 1.minute.ago, status: "running")
    [{ timeout_ms: 1_000, effect_profile: nil }, { timeout_ms: nil, effect_profile: { "timeout_ms" => 500 } }].each do |columns|
      held_ages.each do |age|
        AgentRunTask.where(id: tool.id).update_all(
          columns.merge(status: "needs_approval", started_at: nil, await_started_at: age.ago)
        )
        tool.reload
        assert_equal AgentRunTasks::AwaitTask::MAX_HOLD_MS, tool.effective_timeout_ms,
          "a run clock of #{columns.inspect} must not shorten the hold"
        assert_equal tool.deadline_passed?, frontier_ids.include?(tool.id),
          "held #{columns.inspect} age=#{age.inspect}: the SQL frontier and the locked recheck disagree"
        assert_equal age > AgentRunTasks::AwaitTask::MAX_HOLD, frontier_ids.include?(tool.id),
          "held age=#{age.inspect}: on the frontier iff older than MAX_HOLD"
      end
    end
  end

  # The frontier's own membership, without expiring anything.
  def frontier_ids
    AgentRuns::Parks::TimeoutSweep.new.send(:frontier, DatabaseClock.now).map(&:id)
  end

  # The ask's address is WRITTEN at start and listed in a later step: an agent's loop carries its
  # address on the row, a Human's standalone loop carries nobody — the person's door only.
  test "a tokenless ask on an agent-created loop is addressed to the agent application, on a Human's to nobody" do
    agent = users(:agent)
    asking = model("round1", "tools" => [Nexus::Tools::ASK])

    on_agent = seed(asking, creating_user: agent)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: on_agent, acting_user: agent))
    asked = ask_through_the_model!(on_agent)
    assert_equal "awaiting_input", asked.status
    assert_nil asked.resolution_token
    assert_equal TaskExecutor.address_for(agent).id, asked.addressed_executor_id
    assert_equal "agent_application", asked.addressed_role

    on_human = seed(asking)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: on_human, acting_user: @human))
    asked = ask_through_the_model!(on_human)
    assert_equal "awaiting_input", asked.status
    assert_nil asked.addressed_executor_id
    assert_nil asked.addressed_role
  end

  # THE ASK IS AN INBOX ROW: listed for its addressee with its question, never claimed — one live
  # address per profile and the answer arrives on a person's clock — and committed on the executor
  # plane WITHOUT a token: the row names its addressee and that is the door. The member `resolution`
  # door answers the same row for a person; two doors, ONE Settle, and the second answer is `idle`.
  test "an addressed ask is listed on its addressee's inbox with its question, never claimable, and commits on the executor plane without a token" do
    agent = users(:agent)
    address = TaskExecutor.address_for(agent)
    create_bound_credential(executor: address, name: "Lane transport")
    agent_run = seed(model("round1", "tools" => [Nexus::Tools::ASK]), creating_user: agent)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: agent))
    asked = ask_through_the_model!(agent_run)

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
      agent_run: agent_run, task_key: asked.node_key, executor: address
    ))
    assert_equal :not_claimable_kind, claimed.outcome

    committed = executor_commit(agent_run, asked.node_key, address, content: "Postgres")
    assert_predicate committed, :applied?, committed.outcome.inspect
    asked.reload
    assert_equal "completed", asked.status
    assert_equal "Postgres", asked.content_bodies.find_by!(role: "output").effective_text
    assert_equal [], Executors::Inbox.call(executor: address).tasks, "answered, the row leaves the inbox"
    AgentRuns::EvaluateQuiescence.call(agent_run.reload)
    assert_nil agent_run.reload.attention_reason, "the announcement clears with the answer"

    assert_equal :idle, executor_commit(agent_run, asked.node_key, address, content: "again").outcome,
      "write-once: the second answer on this door settles nothing"
    assert_equal :idle, AgentRuns::Parks::Settle.call(node: asked.reload, content: "MySQL").outcome,
      "two doors, one Settle: the person's door after the agent's is idle"
    assert_equal "Postgres", asked.reload.content_bodies.find_by!(role: "output").effective_text
  end

  test "a Human-created standalone loop's ask lists in no inbox and resolves by standing" do
    address = TaskExecutor.address_for(users(:agent))
    agent_run = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    asked = ask_through_the_model!(agent_run)

    assert_equal [], Executors::Inbox.call(executor: address).tasks,
      "addressed to nobody, the row is nobody's inbox row — the person's door only"
    assert_equal :not_addressed_here, executor_commit(agent_run, asked.node_key, address, content: "x").outcome
    assert_equal "awaiting_input", asked.reload.status

    assert_predicate AgentRuns::Parks::Settle.call(node: asked, content: "Postgres"), :applied?
    assert_equal "completed", asked.reload.status
  end

  # A client-authored await was handed its token in a receipt: a party the
  # kernel does not address holds the proof, so it is never a row.
  test "a tokened await is never a row" do
    address = TaskExecutor.address_for(users(:agent))
    agent_run = seed(ask("gate"), creating_user: users(:agent))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: users(:agent)))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    gate = node(agent_run, "gate")
    assert_equal "dispatched", gate.status

    assert_equal [], Executors::Inbox.call(executor: address).tasks
    assert_equal :not_addressed_here, executor_commit(agent_run, "gate", address, content: "x").outcome
    assert_predicate resolve!(gate), :applied?
  end

  def executor_commit(agent_run, key, executor, content:, outcome: nil)
    Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: key, executor: executor, claim_token: nil,
      content: content, structured_content: nil, result_type: nil, outcome: outcome,
      is_error: false, title: nil, metadata: nil
    ))
  end

  def ask_through_the_model!(agent_run)
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
    round = node(agent_run, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("asking", tool_calls: [
      { id: "call_a", name: "ask", arguments: { prompt: "which?" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentRuns::AskJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end
    agent_run.agent_run_tasks.where(type: AgentRunTasks::AwaitTask.sti_name).sole
  end

  test "an await parks at most 24 hours, each park on its own (Q2, 2026-09-05)" do
    agent_run = seed(
      await("long", "timeout_ms" => 6.days.in_milliseconds),
      await("next", "timeout_ms" => 6.hours.in_milliseconds)
    )
    start!(agent_run)
    long = node(agent_run, "long")
    assert_equal AgentRunTasks::AwaitTask::MAX_HOLD_MS, long.effective_timeout_ms,
      "the authored week is kept as intent; the derived deadline is clamped per park"
    assert_equal 6.days.in_milliseconds, long.await_timeout_ms

    # The first park idled most of a day; the next is NOT tightened by it
    # — there is no budget the parks share, only the clamp each carries.
    long.update_columns(await_started_at: 23.5.hours.ago)
    assert_predicate resolve!(long), :applied?
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    following = node(agent_run, "next")
    assert_equal "dispatched", following.status
    assert_equal 6.hours.in_milliseconds, following.effective_timeout_ms,
      "a loop may park as many times as its work needs"
  end

  test "a refused answer leaves the park retryable" do
    agent_run = seed(await("gate", "timeout_ms" => 6.hours.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")

    # Storage refusing is the LAST guard in the ladder; nothing above it
    # may already have been committed.
    refused_body = ContentBodies::Replace::Result.refused(:unsupported_text)
    result = ContentBodies::Replace.stub(:call, ->(**) { refused_body }) do
      AgentRuns::Parks::Settle.call(
        node: gate, claim_token: gate.resolution_token, content: "unstorable"
      )
    end

    assert_equal :result_unstorable, result.outcome
    assert_equal "dispatched", gate.reload.status
    assert_predicate resolve!(gate), :applied?
  end

  test "a failed resolution keeps the words that explain it" do
    agent_run = seed(await("gate", "on_failure" => "halt"))
    start!(agent_run)
    gate = node(agent_run, "gate")

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
    agent_run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")

    # Pause at +30m; the answer arrives at +2h wall time — mid-pause,
    # past the UNSHIFTED deadline. The virtual clock stands at paused_at,
    # so the deadline has not passed and the answer is accepted.
    AgentRunTask.where(id: gate.id).update_all(await_started_at: 2.hours.ago)
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    agent_run.reload.update_columns(paused_at: 90.minutes.ago)

    assert_predicate resolve!(node(agent_run, "gate"), content: "approved"), :applied?
    gate.reload
    assert_equal "completed", gate.status,
      "DEADLINE WINS reads the virtual clock: frozen time cannot expire a park"
  end

  test "resume repays the pause debt; stop-from-paused repays it too (§9b)" do
    agent_run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")
    armed_at = 30.minutes.ago
    AgentRunTask.where(id: gate.id).update_all(await_started_at: armed_at)

    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    agent_run.reload.update_columns(paused_at: 3.days.ago)

    assert_predicate AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    gate.reload
    assert_in_delta 3.days.since(armed_at), gate.await_started_at, 5,
      "the clock base shifts forward by exactly the pause"
    assert_nil agent_run.reload.paused_at

    # Stop-from-paused: pause again, then stop gracefully — the shift
    # happens in the same locked transaction the drain begins in, so the
    # swept `canceling` state sees only live time.
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    agent_run.reload.update_columns(paused_at: 1.day.ago)
    base_before = gate.reload.await_started_at
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    )), :accepted?
    agent_run.reload
    assert_equal "canceling", agent_run.status
    assert_nil agent_run.paused_at,
      "no canceling loop carries a paused_at"
    assert_in_delta 1.day.since(base_before), gate.reload.await_started_at, 5
    assert_equal "dispatched", gate.status,
      "graceful stop still waits for the rendezvous, on the repaid clock"
  end

  test "the sweep frontier excludes paused loops and keeps canceling swept (§9b)" do
    agent_run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")
    AgentRunTask.where(id: gate.id).update_all(await_started_at: 2.hours.ago)

    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    result = AgentRuns::Parks::TimeoutSweep.call
    assert_equal "dispatched", gate.reload.status,
      "a paused loop's park is not even a candidate"

    # Graceful stop re-exposes the clock (debt repaid: ~0 pause here) —
    # and a canceling loop IS swept: the deadline still ends a drain
    # nobody resolves.
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    )), :accepted?
    AgentRunTask.where(id: gate.id).update_all(await_started_at: 2.hours.ago)
    AgentRuns::Parks::TimeoutSweep.call
    assert_equal "timed_out", gate.reload.status,
      "DEADLINE-WINS ends a graceful stop nobody answers (no-zombie)"
    AgentRuns::EvaluateQuiescence.call(agent_run.reload)
    assert_equal "canceled", agent_run.reload.status
  end

  test "an oversized answer leaves the park standing" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    result = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token,
      content: "x" * (Nexus::SizeBounds::BOUNDS
        .fetch(AgentRuns::Parks::Settle::RESULT_BOUND).fetch(:value) + 1)
    )
    assert_equal :result_too_large, result.outcome
    assert_equal "dispatched", gate.reload.status, "the lease survives; the caller retries bounded"
  end

  # THE BOUNDARY USED TO FAIL OPEN. `content` was stored verbatim as
  # `{"text" => content}` while the size guard measured `content.to_s`, so
  # a submitted Array was sized as one thing and stored as another — and
  # `readable_text`'s `Array#join` then flattened it into a Ruby inspect
  # string that became the model's tool result. No 500, no 422, no log
  # line: the transcript was simply wrong.
  test "a result outside the grammar is refused, not silently flattened" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    {
      { "text" => "hi" } => :invalid_content,
      42 => :invalid_content,
      [{ "text" => "no type" }] => :invalid_content,
      [{ "type" => "text", "text" => 9 }] => :invalid_content,
      ["bare string"] => :invalid_content,
      # A WELL-FORMED BLOCK OF A KIND WE DO NOT CARRY YET gets its own
      # refusal, deliberately: "you sent a shape nobody takes" and "you
      # sent a kind we do not take yet" are different facts, and the
      # second becomes obsolete the round image lands.
      [{ "type" => "image", "upload_public_id" => "x" }] => :unsupported_content_kind,
    }.each do |shape, expected|
      result = AgentRuns::Parks::Settle.call(
        node: gate, claim_token: gate.resolution_token, content: shape
      )
      assert_equal expected, result.outcome, "for #{shape.inspect}"
      assert_equal "dispatched", gate.reload.status, "the lease survives a malformed submission"
      assert_nil gate.content_bodies.find_by(role: "output"),
        "and nothing was written — the old path stored the flattened inspect form"
    end
  end

  # THE IDENTITY CASE IS LOAD-BEARING, not politeness. The
  # `function_call_output` entry IS the prompt-cache breakpoint, so a
  # text-only result whose stored bytes moved would bust the cached prefix
  # of every live loop at the marked position. A bare String and a
  # one-text-block array must write the SAME entry.
  test "a string and a single text block write byte-identical entries" do
    agent_run = seed(parallel(await("a"), await("b")), model("after"))
    start!(agent_run)

    plain = node(agent_run, "a")
    AgentRuns::Parks::Settle.call(
      node: plain, claim_token: plain.resolution_token, content: "the answer"
    )
    blocked = node(agent_run, "b")
    AgentRuns::Parks::Settle.call(
      node: blocked, claim_token: blocked.resolution_token,
      content: [{ "type" => "text", "text" => "the answer" }]
    )

    payloads = [plain, blocked].map do |task|
      task.content_bodies.find_by!(role: "output")
        .content_body_entries.includes(:content_fragment)
        .order(:position).map { |entry| entry.content_fragment.payload }
    end
    assert_equal [{ "text" => "the answer" }], payloads.first
    assert_equal payloads.first, payloads.last,
      "a runner adopting the block spelling must not move one cached byte"
  end

  # THE WHITESPACE DOOR, and it is the cache invariant's real test. The
  # engine's gate has always been `blank?`, so a whitespace-only result
  # writes NO body. Writing one instead is not a cosmetic difference:
  # `effective_text` is `readable_text.presence || canonical_entry_text`,
  # and a blank projection has no `presence` — so the model would be
  # handed `{"text":"\n"}`, the storage envelope's own JSON, exactly the
  # failure this grammar claims to remove. And that entry is the one the
  # prompt-cache breakpoint is stamped on.
  test "a blank result writes no body, whatever whitespace it is made of" do
    agent_run = seed(parallel(await("a"), await("b"), await("c")), model("after"))
    start!(agent_run)

    { "a" => "", "b" => "\n", "c" => "  \t\n " }.each do |key, blank|
      task = node(agent_run, key)
      result = AgentRuns::Parks::Settle.call(
        node: task, claim_token: task.resolution_token, content: blank
      )
      assert_predicate result, :applied?
      assert_nil task.reload.content_bodies.find_by(role: "output"),
        "#{blank.inspect} must write nothing — the model reads \"\" and not a JSON envelope"
    end
  end

  # And with structure beside it (the three channels): a blank text leaves the blocks empty and the
  # structure is STORED, not serialized into the text position — `content` is the model's,
  # `structured_content` the UI's. The model reads `""` in the sealed request, never the value and
  # never the storage envelope; the task read serves the structure whole.
  test "a blank text with structure hands the model nothing and the task read the structure" do
    call, output = paired_output_after(content: "\n", structured_content: { "ok" => true })

    assert_equal "", output, "the pairing's function_call_output is the writer's empty word"
    detail = AgentAPI::AgentRunPresenter.task_detail(call)
    assert_equal "", detail.fetch(:output)
    assert_equal({ "ok" => true }, detail.fetch(:structured_content))
    assert_not detail.key?(:content), "no text block was sent, so none is served"
  end

  # A FALSY STRUCTURED RESULT IS STILL A RESULT. A policy tool whose whole
  # answer is `false` had it written to the body and then served back as
  # absent — indistinguishable from a tool that sent none.
  test "a structured result of false survives the round trip" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token,
      content: "denied", structured_content: false
    )

    detail = AgentAPI::AgentRunPresenter.task_detail(gate.reload)
    assert_equal false, detail.fetch(:structured_content),
      "found by KEY, never by truthiness"
    assert_equal "denied", detail.fetch(:output)
  end

  # A BOUND THE GRAMMAR OWNS, so the refusal is a 422 the runner can act
  # on. Without it the storage count check fired instead and the runner
  # got a 409 — "try again later" about a payload that will never be
  # accepted.
  test "more blocks than the body can hold refuses in the grammar" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    ceiling = Nexus::SizeBounds::BOUNDS
      .fetch(AgentRuns::Parks::ResultContent::MAX_BLOCKS).fetch(:value)
    blocks = ->(n) { Array.new(n) { { "type" => "text", "text" => "x" } } }

    refused = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: blocks.call(ceiling + 1)
    )
    assert_equal :too_many_content_blocks, refused.outcome
    assert_equal "dispatched", gate.reload.status

    applied = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: blocks.call(ceiling)
    )
    assert_predicate applied, :applied?, "the ceiling itself must be storable"
  end

  # SIZING MUST NEVER RAISE, and depth is the case that proved the rescue
  # was too narrow: a structure nested past what can be stored raised a
  # raw JSON::NestingError out of a method whose whole contract is a typed
  # answer, which is a 500 with a backtrace instead of a refusal.
  test "a structure nested past storage refuses instead of raising" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    deep = (1..120).reduce("x") { |inner, _| [inner] }
    result = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, structured_content: deep
    )
    assert_equal :result_unstorable, result.outcome,
      "a typed refusal, not a JSON::NestingError escaping the sizing guard"
    assert_equal "dispatched", gate.reload.status, "the lease survives"
  end

  test "structured content rides beside the text, and never inside it" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token,
      content: "22.5 degrees", structured_content: { "temperature" => 22.5 }
    )

    body = gate.reload.content_bodies.find_by!(role: "output")
    payloads = body.content_body_entries.includes(:content_fragment)
      .order(:position).map { |entry| entry.content_fragment.payload }
    assert_equal [{ "text" => "22.5 degrees" }, { "structured" => { "temperature" => 22.5 } }],
      payloads
    assert_equal "22.5 degrees", body.effective_text,
      "the model reads the text projection; the structured entry is not text"
  end

  # MCP's SHOULD ("a tool that returns structured content SHOULD also return the serialized JSON in
  # a TextContent block") is the RUNNER's to honour, never the kernel's to enforce: structure with
  # no text writes the structured entry ALONE, and the writer's word — `readable_text: ""` — is what
  # keeps `effective_text` from falling back to the canonical entry JSON. The model is handed `""`,
  # not a JSON blob describing its own result, and not the value either.
  test "structured content with no text never reaches the model" do
    call, output = paired_output_after(structured_content: { "ok" => true })

    assert_equal "", output
    body = call.content_bodies.find_by!(role: "output")
    payloads = body.content_body_entries.includes(:content_fragment)
      .order(:position).map { |entry| entry.content_fragment.payload }
    assert_equal [{ "structured" => { "ok" => true } }], payloads, "no serialized text entry beside it"
    assert_equal "", body.readable_text, "the writer's word, stored"
    assert_equal "", body.effective_text
    refute_includes body.effective_text, "structured", "never the storage envelope"
    assert_equal 0, body.byte_size, "the stored size is the bytes effective_text answers (K-2c)"
  end

  test "a result type we cannot honour refuses rather than reading as complete" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    refused = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token,
      content: "hi", result_type: "input_required"
    )
    assert_equal :invalid_result_type, refused.outcome,
      "MRTR is not implemented; accepting its result type would be a lie"

    # Omitting result_type has the same completion behavior as explicitly passing "complete".
    %w[complete].each do |declared|
      applied = AgentRuns::Parks::Settle.call(
        node: gate, claim_token: gate.resolution_token,
        content: "hi", result_type: declared
      )
      assert_predicate applied, :applied?
    end
  end

  # `String.try_convert` is a CONVERSION, not a type check: an object that
  # answers `to_str` IS a string by Ruby's own protocol, and refusing it
  # would be this boundary substituting a type probe for a contract.
  test "a result that converts to text is text" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    stringish = Class.new { def to_str = "converted" }.new
    result = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: stringish
    )
    assert_predicate result, :applied?
    assert_equal "converted",
      gate.reload.content_bodies.find_by!(role: "output").effective_text
  end

  test "the append envelope resolves atomically, and a failed outcome is refused there" do
    agent_run = seed(await("gate"))
    start!(agent_run)

    refused = grow(agent_run, model("late"), resolves: [{ "task" => "gate", "outcome" => "failed" }])
    assert_equal :unsupported_resolve_outcome, refused.outcome
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "late"),
      "one bad entry takes the WHOLE envelope back"
    assert_equal "dispatched", node(agent_run, "gate").status

    applied = grow(agent_run, model("next"), resolves: [{ "task" => "gate", "content" => "from the envelope" }])
    assert_predicate applied, :applied?
    assert_equal "completed", node(agent_run, "gate").status
    assert_equal "from the envelope",
      node(agent_run, "gate").content_bodies.find_by!(role: "output").effective_text
    assert_equal "queued", node(agent_run, "next").status,
      "the task authored in the same envelope depends on the await it resolved"
  end

  test "an unknown await in the envelope refuses without appending" do
    agent_run = seed(model("only"))
    start!(agent_run)

    result = grow(agent_run, ask("extra"), resolves: ["nope"])
    assert_equal :unknown_await, result.outcome
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "extra")
  end
end
