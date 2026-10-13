require "test_helper"

# THE REQUEST HALF OF THE EXECUTOR RELAY: a member's request for something only a runner can answer
# is a ONE-TASK STANDALONE LOOP on the task-grained surface — a seed of a single `tool` step under
# `raw`, created AND STARTED, addressed to the bound runner, granted by its origin, claimed and
# committed through the doors that already exist, and completed by quiescence on the step's settle.
# No round runs, no model is called, no receipt is mailed, nothing compacts. The kernel changes
# NOTHING for it; this file is the proof that it need not, and the pin that a later change to
# `compile_seed` / `refuse_end` / the stage breaks the relay at once rather than in a journey.
class AgentRuns::RequestSeedTest < ActiveJob::TestCase
  KEY = "relay".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  # The seed as the SDK's `request` verb authors it: one tool step under
  # the default word, the runner named, the shell `bypass` — `approval_mode`
  # is inert for an `author`-origin row; `approval_rules` is the shell.
  def request!(name = "read_file", input: { "path" => "note.txt" }, timeout_ms: nil, **shell)
    seed(tool(KEY, name, "input" => input, **({ "timeout_ms" => timeout_ms } if timeout_ms)),
      prompt_mechanism: "raw", **shell)
  end

  def start!(agent_run)
    result = AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    assert_predicate result, :accepted?, result.outcome.inspect
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def node(agent_run) = agent_run.agent_run_tasks.find_by!(node_key: KEY)

  def claim!(agent_run)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: KEY, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def commit!(agent_run, token, content: "note: hello", **fields)
    result = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: KEY, executor: suite_runner, claim_token: token,
      content: content, structured_content: nil, result_type: nil, outcome: "completed",
      is_error: false, title: nil, metadata: nil, **fields
    ))
    assert_predicate result, :applied?, result.outcome.inspect
    result
  end

  # The composition's tail: `stop` behind a request that did not complete, so no `needs_attention`
  # row of a one-task loop lingers.
  def stop!(agent_run)
    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  test "a tool-only seed under raw is admitted, is the deliverable, and starts addressed to the bound runner" do
    agent_run = request!(timeout_ms: 5_000)

    assert_equal "pending", agent_run.status, "created, not started: two intents"
    assert_equal KEY, agent_run.deliverable&.node_key, "the one step is the loop's answer"
    assert_equal 1, agent_run.agent_run_tasks.count, "one task, no edge, no round"
    assert_equal "author", node(agent_run).authored_by
    assert_equal "queued", node(agent_run).status, "nothing dispatches before start"
    assert_nil node(agent_run).await_started_at, "the clock starts at dispatch, never at create"

    start!(agent_run)
    agent_run.reload
    assert_equal "running", agent_run.status
    call = node(agent_run)
    assert_equal "dispatched", call.status
    assert_equal suite_runner.id, call.addressed_executor_id, "addressed to the runner the seed named"
    assert_equal "runner", call.addressed_role
    assert_equal "author", call.approval_origin, "granted by its origin: no rule named `author`"
    assert_equal 5_000, call.effective_timeout_ms, "the step's own clock beats the announced park"
    assert_not_nil call.await_started_at
    assert_empty ModelInvocation.where(agent_run_id: agent_run.id), "no model is called"
  end

  test "the loop completes on the step's settle with no round, no receipt and no compaction" do
    agent_run = request!
    start!(agent_run)
    token = claim!(agent_run)
    commit!(agent_run, token, title: "read note.txt", metadata: { "checkpoint" => "c1" })
    schedule!(agent_run)

    agent_run.reload
    assert_equal "completed", agent_run.status
    assert_equal KEY, agent_run.deliverable&.node_key
    assert_not_nil agent_run.completed_at
    assert_equal "completed", node(agent_run).status
    assert_equal suite_runner.id, node(agent_run).claimed_by_executor_id
    assert_equal 1, agent_run.agent_run_tasks.count, "no continuation, no summarizer: the tool step alone"
    assert_empty ModelInvocation.where(agent_run_id: agent_run.id)
    assert_not AgentRuns::ResultDelivery.pending?(agent_run), "a standalone loop mails no receipt"
    assert_no_enqueued_jobs only: AgentRuns::ResultDeliveryJob
    detail = AgentAPI::AgentRunPresenter.task_detail(node(agent_run))
    assert_equal "note: hello", detail.fetch(:output)
    assert_equal "read note.txt", detail.fetch(:title)
    assert_equal({ "checkpoint" => "c1" }, detail.fetch(:metadata))
  end

  # A replayed create answers the standing loop; a second start is
  # `not_startable` — the composition reads that as "already started".
  test "a replayed create answers the same loop and a second start is not_startable" do
    key = SecureRandom.uuid
    first = create_loop(tool(KEY, "read_file"), prompt_mechanism: "raw", idempotency_key: key)
    assert_predicate first, :created?
    start!(first.agent_run)

    again = create_loop(tool(KEY, "read_file"), prompt_mechanism: "raw", idempotency_key: key)
    assert_predicate again, :replayed?
    assert_equal first.agent_run.id, again.agent_run.id
    second = AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: again.agent_run, acting_user: @human))
    assert_equal :not_startable, second.outcome
  end

  # (a)4's kernel half: an offline runner is an honest wait — the row is
  # never claimed, the sweep settles it `timed_out` at its own deadline
  # (`tool_timeout`), quiescence holds the loop `deliverable_unresolved`,
  # and the composition's `stop` ends it `canceled`. No presence is read.
  test "a request nobody claims is swept timed_out at its deadline, and stop ends the loop it leaves" do
    agent_run = request!(timeout_ms: 5_000)
    start!(agent_run)
    assert_equal "dispatched", node(agent_run).status

    AgentRunTask.where(id: node(agent_run).id).update_all(await_started_at: 2.hours.ago)
    AgentRuns::Parks::TimeoutSweep.call
    clear_enqueued_jobs
    schedule!(agent_run)

    call = node(agent_run)
    assert_equal "timed_out", call.status
    assert_equal "tool_timeout", call.error_key
    assert_nil call.claimed_by_executor_id, "never claimed"
    assert_nil call.claimed_at, "never claimed: no claim stamp"
    agent_run.reload
    assert_equal "needs_attention", agent_run.status
    assert_equal "deliverable_unresolved", agent_run.attention_reason

    stop!(agent_run)
    assert_equal "canceled", agent_run.reload.status
    assert_equal "timed_out", node(agent_run).status, "the settled row keeps its word"
  end

  # (a)5's kernel half: a name the runner never announced fails at start
  # with no fallback, and the loop holds until the composition stops it.
  test "a request for a tool nobody serves fails tool_not_served at start" do
    agent_run = request!("nosuch", input: {})
    start!(agent_run)

    call = node(agent_run)
    assert_equal "failed", call.status
    assert_equal Executors::Address::TOOL_NOT_SERVED, call.error_key
    assert_equal "needs_attention", agent_run.reload.status

    stop!(agent_run)
    assert_equal "canceled", agent_run.reload.status
  end

  # (a)9's kernel half, read off `Executors::Rules#applies?`: a rule
  # addresses the writer its `origin` names (default `model`), so a deny
  # rule written for the model's rows never reaches an `author` seed — the
  # row is granted by its origin. A verb that wants the relay's own row
  # guarded passes the rules WITH `origin: author`; then the stage denies
  # it before dispatch and the loop holds until stopped.
  test "a deny rule reaches the seed only when it names the author origin" do
    rule = { "tool" => "bash", "path" => "command", "match" => "*rm -?? /", "verdict" => "deny",
             "reason" => "recursive delete of a root directory" }
    granted = request!("bash", input: { "command" => "rm -rf /" }, approval_rules: [rule])
    start!(granted)
    assert_equal "dispatched", node(granted).status, "a model-origin rule does not address an author row"
    assert_equal "author", node(granted).approval_origin

    denied = request!("bash", input: { "command" => "rm -rf /" },
      approval_rules: [rule.merge("origin" => "author")])
    start!(denied)
    call = node(denied)
    assert_equal "failed", call.status
    assert_equal AgentRuns::Tasks::Deny::ERROR_KEY, call.error_key
    assert_equal "recursive delete of a root directory", call.error_detail
    assert_nil call.claimed_by_executor_id, "denied before dispatch: nobody ever held it"
    assert_equal "needs_attention", denied.reload.status

    stop!(denied)
    assert_equal "canceled", denied.reload.status
  end
end
