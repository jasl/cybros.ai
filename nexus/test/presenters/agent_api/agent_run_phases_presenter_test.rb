require "test_helper"

# HOW FAR ALONG: the plan IS the receipts' step mirrors in write order, every kernel round counts
# inside the phase it extends, and nothing is stored to answer it.
class AgentAPI::AgentRunPhasesPresenterTest < ActiveJob::TestCase
  include InvocationHarness
  include ActiveRecord::Assertions::QueryAssertions

  READ_FILE = { "type" => "function", "function" => {
    "name" => "read_file", "description" => "read", "parameters" => { "type" => "object" },
  } }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a kernel fan and its continuation count inside the phase of the round they extend" do
    agent_run = seed(model("plan", "tools" => [READ_FILE]), ask("gate"))
    start!(agent_run)
    run_step!(agent_run, "plan",
      sse_success("look", tool_calls: [{ id: "c1", name: "read_file", arguments: "{}" }]))

    progress = AgentAPI::AgentRunPhasesPresenter.call(agent_run.reload)

    assert_equal %w[plan gate], progress.phases.map(&:label), "the kernel's rows are no phase of their own"
    plan = progress.phases.first
    assert_equal({ label: "plan", keys: ["plan"], done: 1, total: 1, status: "running" }, plan.to_h,
      "the round answered, but its fan is parked and its continuation queued: the phase is still running")
    assert_equal 0, progress.current
    assert_equal [], progress.background
    assert_equal({ input_tokens: 2, output_tokens: 3, cache_read_tokens: 0, cache_hit_rate: 0.0, cost_amount: "0.0", cost_unit: nil,
                   by_model: { "dev/mock-text" => { input_tokens: 2, output_tokens: 3, cache_read_tokens: 0,
                                                    cost_amount: "0.0", cost_unit: nil } } },
      progress.spend, "the dev lane is admitted free: an exact zero, not an unknown; the cache read rides with its rate")
  end

  # THE SPLIT A SWITCHED STEP LEAVES: a loop whose receipts came from two models — a refused step
  # re-run on the answerer's declared fallback is the reachable case — reads each model's own sums
  # beside the loop's, grouped by the receipt's own provider and catalog model, so a reader never
  # re-prices a receipt to tell whose spend it was. An unpriced receipt keeps its model's money
  # unknown while another model's exact zero stands.
  test "the spend splits the loop's receipts by the model each receipt names" do
    agent_run = seed(model("a"), model("b", "model" => { "model" => "dev/mock-unmetered" }))
    start!(agent_run)
    run_step!(agent_run, "a", sse_success("one"))
    run_step!(agent_run, "b", sse_success("two", usage: { "input_tokens" => 7, "output_tokens" => 5 }))

    spend = AgentAPI::AgentRunPhasesPresenter.call(agent_run.reload).spend

    assert_equal({ "dev/mock-text" => { input_tokens: 2, output_tokens: 3, cache_read_tokens: 0, cost_amount: "0.0", cost_unit: nil },
                   "dev/mock-unmetered" => { input_tokens: 7, output_tokens: 5, cache_read_tokens: 0, cost_amount: nil, cost_unit: nil } },
      spend.fetch(:by_model))
    assert_equal [9, 8], spend.values_at(:input_tokens, :output_tokens), "the loop's sums are every model's together"
  end

  test "every authored envelope is a plan, keyed or not, and a kernel one is not" do
    agent_run = seed(model("plan"), ask("gate"))
    agent_run.agent_run_tasks.find_by!(node_key: "plan")
      .update_columns(status: "completed", completed_at: Time.current)
    grow!(agent_run, parallel(tool("tests"), tool("lint")), model("final"))
    AgentRuns::WakeContinuation.plant(agent_run: agent_run, source: agent_run.agent_run_tasks.find_by!(node_key: "plan"))

    progress = AgentAPI::AgentRunPhasesPresenter.call(agent_run.reload)

    assert_equal ["plan", "gate", "tests · lint", "final"], progress.phases.map(&:label)
    assert_equal [["plan"], ["gate"], %w[tests lint], ["final"]], progress.phases.map(&:keys)
    assert_equal 2, agent_run.agent_run_append_receipts.count, "two authored envelopes, no kernel receipt"
    assert_equal %w[completed waiting waiting waiting], progress.phases.map(&:status)
    assert_equal 1, progress.current, "the first phase not yet completed"
  end

  # Pure over doubles: the status words, the background tips, and a
  # detached round attached to the phase of the round that started it.
  test "phase words follow the rows, and detached tips still to settle or already mailed are background" do
    row = Data.define(:node_key, :task_kind, :status, :sources, :detached, :failure_resolution, :result_delivered_at,
      :on_failure) do
      def initialize(result_delivered_at: nil, on_failure: "halt", **) = super
    end
    plan = row.new(node_key: "plan", task_kind: "model_task", status: "completed", sources: [],
      detached: false, failure_resolution: nil)
    branch = row.new(node_key: "r1t0-model-1", task_kind: "model_task", status: "running",
      sources: [plan], detached: true, failure_resolution: nil)
    gate = row.new(node_key: "gate", task_kind: "await_task", status: "awaiting_input",
      sources: [plan], detached: false, failure_resolution: nil)
    program = row.new(node_key: "program", task_kind: "tool_task", status: "awaiting_input",
      sources: [], detached: false, failure_resolution: nil)
    broken = row.new(node_key: "final", task_kind: "model_task", status: "failed",
      sources: [gate], detached: false, failure_resolution: nil)
    # A settled tip nothing waits on is background only once it was mailed after the reply went
    # final; one the wake read is not.
    result_delivered_at = Time.utc(2026, 9, 6, 0, 0, 9)
    mailed = row.new(node_key: "r1t1-model-1", task_kind: "model_task", status: "completed",
      sources: [plan], detached: true, failure_resolution: nil, result_delivered_at: result_delivered_at)
    read = row.new(node_key: "r1t2-model-1", task_kind: "model_task", status: "failed",
      sources: [plan], detached: true, failure_resolution: nil, on_failure: "absorb")

    progress = AgentAPI::AgentRunPhasesPresenter.build(
      nodes: [plan, branch, gate, program, broken, mailed, read],
      plans: [["plan"], [{ "parallel" => [["gate"]] }, "program", "final"]],
      spend: { input_tokens: 1, output_tokens: 1, cost_amount: "0.5", cost_unit: "USD" }
    )

    assert_equal %w[running awaiting_human running failed], progress.phases.map(&:status),
      "a program waiting on children stays running; an ask waits for a person"
    assert_equal 0, progress.current
    assert_equal [{ key: "r1t0-model-1", status: "running" },
                  { key: "r1t1-model-1", status: "completed", result_delivered_at: result_delivered_at }], progress.background
    assert_equal({ phases: progress.phases.map(&:to_h), current: 0,
                   background: [{ key: "r1t0-model-1", status: "running" },
                                { key: "r1t1-model-1", status: "completed", result_delivered_at: result_delivered_at }],
                   spend: { input_tokens: 1, output_tokens: 1, cost_amount: "0.5", cost_unit: "USD" } },
      progress.to_h)
    done = AgentAPI::AgentRunPhasesPresenter.build(nodes: [plan], plans: [["plan"]], spend: {})
    assert_nil done.current, "nothing left to do"
  end

  test "an unresolved uncertain step reads failed, and an adjudicated one completed" do
    row = Data.define(:node_key, :task_kind, :status, :sources, :detached, :failure_resolution, :result_delivered_at,
      :on_failure) do
      def initialize(result_delivered_at: nil, on_failure: "halt", **) = super
    end
    held = row.new(node_key: "job", task_kind: "tool_task", status: "uncertain", sources: [],
      detached: false, failure_resolution: nil)
    adjudicated = row.new(node_key: "job", task_kind: "tool_task", status: "uncertain", sources: [],
      detached: false, failure_resolution: "abandoned")
    absorbed = row.new(node_key: "job", task_kind: "tool_task", status: "uncertain", sources: [],
      detached: false, failure_resolution: nil, on_failure: "absorb")

    assert_equal ["failed"], AgentAPI::AgentRunPhasesPresenter.build(
      nodes: [held], plans: [["job"]], spend: {}
    ).phases.map(&:status), "a possibly-escaped effect nobody adjudicated is a failure to look at"
    assert_equal ["completed"], AgentAPI::AgentRunPhasesPresenter.build(
      nodes: [adjudicated], plans: [["job"]], spend: {}
    ).phases.map(&:status)
    assert_equal ["completed"], AgentAPI::AgentRunPhasesPresenter.build(
      nodes: [absorbed], plans: [["job"]], spend: {}
    ).phases.map(&:status), "an absorbed failure is resolved by its policy — the presenter reads on_failure, never a stamp"
  end

  # the route was O(n²) in the loop's rows — every kernel round walked its whole mainline back to a
  # plan key through unpreloaded hops, nothing found was kept, and a 134-round exit-long loop
  # answered in 50–183 s at 59 553 queries a call, past the harness's read timeout. The projection
  # is one preload and one memoized walk: the query count is a constant of the shape, never of the
  # length.
  KERNEL_ROUNDS = 200
  # Nodes, edges, the source rows of the preload, the receipts, and the
  # three spend reads (the sums, the unit, the per-model split).
  PROJECTION_QUERIES = 7

  test "a mainline of two hundred kernel rounds renders in a constant number of queries, well under a second" do
    agent_run = seed(model("plan"))
    plan = agent_run.agent_run_tasks.find_by!(node_key: "plan")
    plan.update_columns(status: "completed", completed_at: Time.current)
    chain_kernel_rounds!(agent_run, after: plan, rounds: KERNEL_ROUNDS)

    progress = nil
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_queries_count(PROJECTION_QUERIES) { progress = AgentAPI::AgentRunPhasesPresenter.call(agent_run) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1.0, "the walk is in memory: #{elapsed.round(3)} s"
    assert_equal({ label: "plan", keys: ["plan"], done: 1, total: 1, status: "running" }, progress.phases.sole.to_h,
      "the deepest round, #{KERNEL_ROUNDS} hops from the plan's key, still counts inside its phase")
    assert_equal 0, progress.current
    assert_equal [], progress.background
    nodes = agent_run.agent_run_tasks.includes(:sources).order(:created_at, :id).to_a
    assert_equal progress.to_h,
      AgentAPI::AgentRunPhasesPresenter.build(nodes: nodes, plans: [["plan"]], spend: progress.spend).to_h,
      "the route and the pure projection agree on the bytes"
  end

  private

    # The kernel's own shape, written straight to the tables: round n's
    # fan reads round n-1, and round n reads both — the continuation's
    # model source first, as the walk chooses it.
    def chain_kernel_rounds!(agent_run, after:, rounds:)
      previous = after
      rounds.times do |n|
        number = n + 1
        running = number == rounds
        fan, round = AgentRunTask.insert_all([
          kernel_row(agent_run, "r#{number}t0", "AgentRunTasks::ToolTask", "completed", "read_file"),
          kernel_row(agent_run, "r#{number}", "AgentRunTasks::ModelTask", running ? "running" : "completed", nil),
        ], returning: %w[id]).rows.map(&:first)
        AgentRunEdge.insert_all([
          edge_row(agent_run, previous.id, fan), edge_row(agent_run, previous.id, round), edge_row(agent_run, fan, round),
        ])
        previous = AgentRunTask.new(id: round)
      end
    end

    def kernel_row(agent_run, key, type, status, tool_name)
      { account_id: agent_run.account_id, agent_run_id: agent_run.id, node_key: key, type: type,
        status: status, authored_by: "kernel", tool_name: tool_name }
    end

    def edge_row(agent_run, from, to)
      { account_id: agent_run.account_id, agent_run_id: agent_run.id, from_node_id: from, to_node_id: to }
    end

    def start!(agent_run)
      AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
      clear_enqueued_jobs
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end

    def run_step!(agent_run, key, behaviour)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted
        .to_h { |candidate| [candidate.attempt.model_invocation_id, candidate.attempt] }
      clear_enqueued_jobs
      node = agent_run.agent_run_tasks.find_by!(node_key: key)
      apply_via(admitted.fetch(node.selected_model_invocation_id), behaviour)
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end
end
