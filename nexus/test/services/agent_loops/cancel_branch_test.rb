require "test_helper"

# THE PERSON-SIDE BRANCH CANCEL: the descendant closure of the named node along outgoing edges,
# stopping at every round-marked node; the target is the CALL key the model saw or any branch node;
# the spine refuses `not_a_branch`. A cancel RESOLVES — the one cancel that does — so a blocking
# consumer runs and reads `status="canceled"`, and a background tip is delivered canceled.
class AgentLoops::CancelBranchTest < ActiveJob::TestCase
  include InvocationHarness

  READ_FILE = { "type" => "function",
                "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def model(key, **over)
    super(key, "tools" => [Nexus::Tools::TASK, READ_FILE], **over)
  end

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_loop)
  end

  def schedule!(agent_loop) = AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def step_attempt(agent_loop, key)
    invocation_id = node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def loop_with_round
    agent_loop = seed(model("round1", "prompt" => "do the work"))
    start!(agent_loop)
    agent_loop
  end

  def calls!(agent_loop, key, name, *arguments)
    tool_calls = arguments.each_with_index.map do |fields, index|
      { id: "call_#{key}_#{index}", name: name, arguments: fields.to_json }
    end
    apply_via(step_attempt(agent_loop, key), sse_success("calling", tool_calls: tool_calls))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      schedule!(agent_loop)
    end
    agent_loop.reload
  end

  def run!(agent_loop, key, text)
    apply_via(step_attempt(agent_loop, key), sse_success(text))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)
  end

  def cancel(agent_loop, key)
    AgentLoops::CancelBranch.call(AgentLoops::CancelBranch::Command.new(
      agent_loop: agent_loop, task_key: key, acting_user: @human
    ))
  end

  def settled!(agent_loop, key)
    row = node(agent_loop, key)
    assert_equal %w[canceled task_canceled canceled], [row.status, row.error_key, row.failure_resolution], key
    assert_equal :resolved, AgentLoops::Graph.settlement_of(row), "a person's cancel resolves"
    row
  end

  def request_payloads(agent_loop, key)
    ModelInvocation.find(node(agent_loop, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
  end

  def paired_results(agent_loop, key)
    request_payloads(agent_loop, key).select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def envelope(task, status, prompt, text)
    "<task_result task=\"#{task}\" status=\"#{status}\">\n<prompt>#{prompt}</prompt>\n#{text}\n</task_result>"
  end

  test "a running waited branch is canceled by its call key, and the consumer reads the cancel" do
    agent_loop = loop_with_round
    calls!(agent_loop, "round1", "task", { prompt: "review the models", wait: true })
    assert_equal "running", node(agent_loop, "r1t0-model-1").status

    result = cancel(agent_loop, "r1t0")
    assert_predicate result, :accepted?
    assert_equal "r1t0", result.node.node_key
    assert_equal "running", node(agent_loop, "r1t0-model-1").status, "in flight: the converger applies it"
    assert_equal "canceled", ModelInvocation.find(node(agent_loop, "r1t0-model-1").selected_model_invocation_id).status
    assert_equal "task_canceled", ModelInvocation.find(node(agent_loop, "r1t0-model-1").selected_model_invocation_id).failure_reason_key

    AgentLoops::ConvergeTerminalSteps.call
    settled!(agent_loop, "r1t0-model-1")
    assert_equal "completed", node(agent_loop, "r1t0").status, "the call itself already answered"
    schedule!(agent_loop)
    assert_equal "running", node(agent_loop, "r1").status, "the blocking consumer runs on the resolution"
    run!(agent_loop, "r1", "noted")
    assert_equal envelope("r1t0", "canceled", "review the models", AgentLoops::TaskResultEnvelope::CANCELED),
      paired_results(agent_loop, "r1").fetch("call_round1_0")
    assert_equal "completed", agent_loop.reload.status
  end

  test "the closure follows the branch's own rounds and stops at the spine" do
    agent_loop = loop_with_round
    calls!(agent_loop, "round1", "task", { prompt: "dig in", wait: true })
    calls!(agent_loop, "r1t0-model-1", "read_file", { path: "a" })
    assert_equal %w[dispatched queued queued], %w[r2t0 r2 r1].map { |key| node(agent_loop, key).status }
    # The branch's parked call is HELD by a runner: the cancel reaches the claimant on its own
    # stream (`work_canceled`) so it kills what it spawned; the row leaving the inbox is the fact.
    assert_predicate Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: "r2t0", executor: suite_runner
    )), :accepted?

    broadcasts = []
    result = ActionCable.server.stub(:broadcast, ->(stream, payload) { broadcasts << [stream, payload] }) do
      cancel(agent_loop, "r1t0-model-1")
    end
    assert_predicate result, :accepted?, result.outcome.inspect
    assert_includes broadcasts, [
      AgentAPI::V1::ExecutorInboxChannel.stream_name(suite_runner.public_id),
      { event: { type: Executors::Nudge::WORK_CANCELED, agent_loop_public_id: agent_loop.public_id,
                 task_key: "r2t0" } },
    ]
    settled!(agent_loop, "r2t0")
    settled!(agent_loop, "r2")
    assert_equal "completed", node(agent_loop, "r1t0-model-1").status, "a settled root is left as it settled"
    assert_equal "queued", node(agent_loop, "r1").status, "the spine consumer is never canceled"
    assert_equal 0, node(agent_loop, "r1").remaining_dependencies, "the resolution released it"

    schedule!(agent_loop)
    run!(agent_loop, "r1", "noted")
    assert_equal envelope("r1t0", "canceled", "dig in", AgentLoops::TaskResultEnvelope::CANCELED),
      paired_results(agent_loop, "r1").fetch("call_round1_0")
  end

  test "a detached branch canceled on a standalone loop is delivered canceled by the wake" do
    agent_loop = loop_with_round
    calls!(agent_loop, "round1", "task", { prompt: "long test run" })
    run!(agent_loop, "r1", "meanwhile")
    assert_equal "running", agent_loop.reload.status

    assert_predicate cancel(agent_loop, "r1t0"), :accepted?
    AgentLoops::ConvergeTerminalSteps.call
    settled!(agent_loop, "r1t0-model-1")
    schedule!(agent_loop)
    wake = node(agent_loop, "w1")
    assert_equal %w[r1 r1t0-model-1], wake.input_from_node_keys
    assert_equal ["r1t0-model-1"], wake.sources.map(&:node_key), "a resolved tip is waited on, like an answered one"
    texts = request_payloads(agent_loop, "w1").filter_map { |payload| payload.dig("parts", 0, "text") }
    assert_includes texts, envelope("r1t0", "canceled", "long test run", AgentLoops::TaskResultEnvelope::CANCELED)
  end

  test "the spine and its fan members refuse not_a_branch; the rest of the refusals by name" do
    agent_loop = loop_with_round
    calls!(agent_loop, "round1", "read_file", { path: "a" })
    assert_equal :not_a_branch, cancel(agent_loop, "round1").outcome, "a round-marked key is stop's"
    assert_equal :not_a_branch, cancel(agent_loop, "r1t0").outcome, "a spine fan member is the round's"
    assert_equal :not_a_branch, cancel(agent_loop, "r1").outcome
    assert_equal :task_not_found, cancel(agent_loop, "nope").outcome
    assert_equal "dispatched", node(agent_loop, "r1t0").status, "nothing moved"
  end

  test "a terminal branch answers already_terminal, and a terminal loop is not adjudicable" do
    agent_loop = loop_with_round
    calls!(agent_loop, "round1", "task", { prompt: "quick", wait: true })
    run!(agent_loop, "r1t0-model-1", "done")
    assert_equal :already_terminal, cancel(agent_loop, "r1t0").outcome

    run!(agent_loop, "r1", "noted")
    assert_equal "completed", agent_loop.reload.status
    assert_equal :not_adjudicable, cancel(agent_loop, "r1t0").outcome
  end

  test "a join loser and a stopped loop's cancel still skip: only a person's cancel resolves" do
    settlement = ->(**row) { AgentLoops::Graph.settlement(on_failure: "absorb", **row) }
    assert_equal :skip, settlement.call(status: "canceled", failure_resolution: nil)
    assert_equal :resolved, settlement.call(status: "canceled", failure_resolution: "canceled")
    assert_equal :skip, settlement.call(status: "skipped", failure_resolution: "canceled")
  end
end
