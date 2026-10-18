require "test_helper"

class Runs::TaskWaitsTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def wait_step(key, task, **options)
    { "wait" => { "key" => key, "task" => task }.merge(options.stringify_keys) }
  end

  def start_loop(*steps)
    run = seed(*steps)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    schedule_loop!(run)
    run
  end

  def resolve(node, text = "original result")
    result = Runs::Parks::Settle.call(node: node, claim_token: node.resolution_token,
      outcome: "completed", content: text)
    assert_predicate result, :applied?
  end

  def wait_result(run, key)
    AgentAPI::RunPresenter.task_detail(loop_node(run, key)).fetch(:structured_content)
  end

  def attempt_for(run, key)
    ModelInvocations::AdmitQueuedWork.call
    invocation = loop_node(run, key).selected_model_invocation_id
    ModelInvocationAttempt.where(model_invocation_id: invocation).order(:id).last
  end

  def answer(run, key, text, calls: [])
    apply_via(attempt_for(run, key), sse_success(text, tool_calls: calls))
    Runs::ConvergeTerminalSteps.call
    schedule_loop!(run)
  end

  def model_call(id, name, **arguments)
    { id: id, name: name, arguments: arguments.to_json }
  end

  test "a later wait observes already completed work and keeps its token private" do
    run = start_loop(detached(ask("work")), ask("gate"), wait_step("joined", "work"))
    work, gate, joined = %w[work gate joined].map { |key| loop_node(run, key) }
    assert_equal "queued", joined.status
    resolve(work)
    resolve(gate)
    schedule_loop!(run)

    assert_equal "completed", joined.reload.status
    assert_equal "original result", wait_result(run, "joined").fetch("results").sole.fetch("output")
    receipt = run.run_append_receipts.order(:id).first.response_body
    assert receipt.fetch("resolution_tokens").key?("work")
    refute receipt.fetch("resolution_tokens").key?("joined")
    assert_nil joined.addressed_executor_id
    assert_nil joined.inbox_kind
  end

  test "an active target remains independent of wait timeout and a repeated wait reads its result" do
    run = start_loop(detached(ask("work")), wait_step("first", "work", timeout_ms: 1),
      wait_step("second", "work"))
    assert_equal "dispatched", loop_node(run, "first").status
    assert_equal :stale_claim, Runs::Parks::Settle.call(node: loop_node(run, "first"),
      content: "forged", outcome: "completed").outcome

    travel 1.second do
      Runs::Parks::TimeoutSweep.call
      schedule_loop!(run)
      assert_equal "timed_out", loop_node(run, "first").status
      assert_equal "await_timeout", loop_node(run, "first").error_key
      assert_equal "dispatched", loop_node(run, "work").status
      assert_equal "dispatched", loop_node(run, "second").status
      resolve(loop_node(run, "work"))
      schedule_loop!(run)
      assert_equal "completed", loop_node(run, "second").status
    end
  end

  test "canceling a detached wait never cancels its target" do
    run = start_loop(detached(ask("work")),
      wait_step("observer", "work", detached: true), ask("gate"))
    result = Runs::CancelBranch.call(Runs::CancelBranch::Command.new(
      run: run, task_key: "observer", acting_user: @human))
    assert_predicate result, :accepted?
    assert_equal "canceled", loop_node(run, "observer").status
    assert_equal "dispatched", loop_node(run, "work").status
    resolve(loop_node(run, "work"))
    schedule_loop!(run)
    assert_equal "canceled", loop_node(run, "observer").status
  end

  test "waiting on a race returns its winner without waiting for run out losers" do
    run = start_loop(parallel(ask("fast"), ask("slow"), until: "any", losers: "run_out", key: "race"),
      wait_step("joined", "race"))
    resolve(loop_node(run, "fast"), "winner")
    schedule_loop!(run)
    assert_equal "completed", loop_node(run, "joined").status
    assert_equal "dispatched", loop_node(run, "slow").status
    result = wait_result(run, "joined").fetch("results").sole
    assert_equal "fast", result.fetch("task")
    assert_equal "winner", result.fetch("output")
  end

  # A FAILED RACE hands the wait what it captured before failing, then its own failure — the one
  # selection a stage, a model step and detached delivery read too.
  test "waiting on a failed quorum returns its partial winner, then its failure" do
    run = start_loop(parallel(ask("a"), ask("b"), ask("c"), until: 2, key: "race", on_failure: "absorb"),
      wait_step("joined", "race"))
    resolve(loop_node(run, "a"), "first")
    %w[b c].each do |key|
      node = loop_node(run, key)
      declined = Runs::Parks::Settle.call(node: node, claim_token: node.resolution_token,
        outcome: "failed", content: "declined")
      assert_predicate declined, :applied?
    end
    schedule_loop!(run)

    assert_equal %w[failed quorum_unreachable], loop_node(run, "race").values_at(:status, :error_key)
    assert_equal "completed", loop_node(run, "joined").status
    results = wait_result(run, "joined").fetch("results")
    assert_equal [%w[a completed], %w[race failed]], results.map { |result| result.values_at("task", "status") }
    assert_equal "first", results.first.fetch("output")
    assert_equal "quorum_unreachable", results.last.dig("error", "key")
  end

  test "missing and foreign standalone targets refuse without partial append" do
    source = start_loop(ask("work"))
    waiter = start_loop(ask("gate"))
    %w[missing work].each do |key|
      assert_no_difference -> { waiter.tasks.count } do
        result = grow(waiter, wait_step("joined", key, run_public_id: source.public_id))
        assert_equal :wait_target_not_found, result.outcome
      end
    end
  end

  test "the model can start a task and wait later for its generated final round" do
    tools = [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::WAIT, READ_TOOL]
    run = start_loop(model("seed", "tools" => tools))
    answer(run, "seed", "start", calls: [model_call("launch", "delegate_task", prompt: "investigate")])
    Runs::DelegateTaskTool::Run.call(node: loop_node(run, "r1t0"))
    schedule_loop!(run)
    answer(run, "r1", "need result", calls: [model_call("observe", "wait", task: "r1t0")])
    Runs::WaitTool::Run.call(node: loop_node(run, "r2t0"))
    schedule_loop!(run)
    assert_equal "queued", loop_node(run, "r2").status
    assert_equal "dispatched", loop_node(run, "r2t0-wait-1").status

    answer(run, "r1t0-model-1", "inspect", calls: [model_call("read", "read_file", path: "a")])
    read = run.tasks.find_by!(tool_call_id: "read")
    Runs::Parks::Settle.call(node: read, trusted: true, content: "bytes", outcome: "completed")
    schedule_loop!(run)
    assert_equal "dispatched", loop_node(run, "r2t0-wait-1").status
    answer(run, "r3", "final investigation")
    schedule_loop!(run)

    result = wait_result(run, "r2t0-wait-1")
    assert_equal "r1t0", result.fetch("task")
    assert_equal "Mock: final investigation", result.fetch("results").sole.fetch("output")
    output = round_request_entries(loop_node(run, "r2"))
      .find { |entry| entry["type"] == "tool_result_item" && entry.dig("payload", "call_id") == "observe" }
      .dig("payload", "output")
    assert_includes output, "final investigation"
    refute_includes output, "Waiting for the existing task."
  end

  test "self and an expanding ancestor are refused instead of parking on themselves" do
    run = start_loop(model("seed", "tools" => [Nexus::Tools::WAIT]))
    answer(run, "seed", "bad wait", calls: [model_call("observe", "wait", task: "seed")])
    call = loop_node(run, "r1t0")
    Runs::WaitTool::Run.call(node: call)
    assert call.reload.output_summary.fetch("is_error")
    assert_includes call.output_body.effective_text, "wait_cycle"
    refute run.tasks.exists?(node_key: "r1t0-wait-1")
  end

  test "a later turn waits on the old task and a lost completion wake is recovered" do
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::WAIT, READ_TOOL])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, original = materialize_loop_reply!(conversation, agent: @agent, text: "start work")
    schedule_loop!(original)
    answer(original, "r1", "start", calls: [model_call("launch", "delegate_task", prompt: "investigate")])
    Runs::DelegateTaskTool::Run.call(node: loop_node(original, "r2t0"))
    schedule_loop!(original)
    answer(original, "r2", "I will finish later")
    Conversations::Turns::Converge.call(conversation_id: conversation.id)
    assert original.reload.delivered?

    _turn, current = materialize_loop_reply!(conversation, agent: @agent, text: "wait now")
    schedule_loop!(current)
    answer(current, "r1", "join", calls: [model_call("observe", "wait", task: "r2t0", run_public_id: original.public_id)])
    Runs::WaitTool::Run.call(node: loop_node(current, "r2t0"))
    schedule_loop!(current)
    assert_equal "dispatched", loop_node(current, "r2t0-wait-1").status
    answer(original, "r2t0-model-1", "background report")
    clear_enqueued_jobs
    Runs::ScheduleSweep.call
    assert_equal "completed", loop_node(current, "r2t0-wait-1").status
    assert_equal "Mock: background report", wait_result(current, "r2t0-wait-1").fetch("results").sole.fetch("output")
  end

  test "a spawn wait observes the original reply after later child conversation activity" do
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, Nexus::Tools::WAIT, READ_TOOL])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, parent = materialize_loop_reply!(conversation, agent: @agent, text: "delegate")
    schedule_loop!(parent)
    answer(parent, "r1", "start", calls: [model_call("launch", "spawn", prompt: "original question")])
    call = loop_node(parent, "r2t0")
    Runs::Spawn::Run.call(node: call)
    schedule_loop!(parent)
    child = call.spawned_conversation
    result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert_predicate result, :accepted?
    original = result.value.active_variant.run
    schedule_loop!(original)

    answer(parent, "r2", "wait later", calls: [model_call("observe", "wait", task: "r2t0")])
    Runs::WaitTool::Run.call(node: loop_node(parent, "r3t0"))
    schedule_loop!(parent)
    assert_equal "dispatched", loop_node(parent, "r3t0-wait-1").status
    answer(original, "r1", "original reply")
    Conversations::Turns::Converge.call(conversation_id: child.id)
    Runs::Spawn::Relay.call(conversation_id: child.id)
    schedule_loop!(parent)
    assert_equal "Mock: original reply", wait_result(parent, "r3t0-wait-1").fetch("output")

    _turn, later = materialize_loop_reply!(child, agent: @agent, text: "different question")
    schedule_loop!(later)
    answer(later, "r1", "different reply")
    result = Runs::TaskWaits::Observe.call(call.reload)
    assert_equal "Mock: original reply", result.data.fetch("output")
    assert_equal child.public_id, result.data.fetch("conversation")
  end

  test "waiting on a denied spawn preserves the approval failure" do
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, Nexus::Tools::WAIT], approval_mode: "ask",
      approval_rules: [{ "tool" => "wait", "verdict" => "allow" }])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, run = materialize_loop_reply!(conversation, agent: @agent, text: "delegate")
    schedule_loop!(run)
    answer(run, "r1", "start", calls: [model_call("launch", "spawn", prompt: "original question")])
    call = loop_node(run, "r2t0")
    assert_equal "needs_approval", call.status

    denied = Runs::Tasks::Deny.call(Runs::Tasks::Deny::Command.new(
      run: run, task_key: call.node_key, acting_user: @human, reason: "keep the work here"))
    assert_predicate denied, :accepted?
    assert_equal ["failed", "approval_denied", "keep the work here"],
      call.reload.values_at(:status, :error_key, :error_detail)
    assert_nil call.spawned_conversation
    schedule_loop!(run)

    answer(run, "r2", "check the task", calls: [model_call("observe", "wait", task: call.node_key)])
    Runs::WaitTool::Run.call(node: loop_node(run, "r3t0"))
    schedule_loop!(run)

    observed = wait_result(run, "r3t0-wait-1")
    assert_equal "completed", observed.fetch("status")
    result = observed.fetch("results").sole
    assert_equal "failed", result.fetch("status")
    assert_equal({ "key" => "approval_denied", "detail" => "keep the work here" }, result.fetch("error"))
    assert loop_node(run, "r3t0-wait-1").output_summary.fetch("is_error")
    # A kernel tool's row is a tool call like any other: observed as the tip, it names its call.
    lines = loop_node(run, "r3t0-wait-1").output_body.effective_text.lines(chomp: true)
    assert_equal "<task_result task=\"r2t0\" status=\"failed\">", lines.first
    assert_match(/\A<call>spawn \{.*"prompt":"original question".*\}<\/call>\z/, lines.second)
    assert_equal "approval_denied: keep the work here", lines.third
  end

  test "a later turn observes a spawn canceled before its job ran" do
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, Nexus::Tools::WAIT])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    turn, original = materialize_loop_reply!(conversation, agent: @agent, text: "delegate")
    schedule_loop!(original)
    answer(original, "r1", "start", calls: [model_call("launch", "spawn", prompt: "original question")])
    call = loop_node(original, "r2t0")
    assert_equal "running", call.status
    assert_nil call.spawned_conversation

    stopped = Runs::Stop.call(Runs::Stop::Command.forced(
      run: original, acting_user: @human))
    assert_predicate stopped, :accepted?
    assert_equal %w[canceled run_canceled], call.reload.values_at(:status, :error_key)
    schedule_loop!(original)
    Conversations::Turns::Converge.call(conversation_id: conversation.id)
    assert_equal "canceled", turn.reload.status

    _turn, current = materialize_loop_reply!(conversation, agent: @agent, text: "check the old task")
    assert_not_equal original.id, current.id
    schedule_loop!(current)
    answer(current, "r1", "observe", calls: [
      model_call("observe", "wait", task: call.node_key, run_public_id: original.public_id),
    ])
    Runs::WaitTool::Run.call(node: loop_node(current, "r2t0"))
    schedule_loop!(current)

    observed = wait_result(current, "r2t0-wait-1")
    assert_equal "completed", observed.fetch("status")
    result = observed.fetch("results").sole
    assert_equal "canceled", result.fetch("status")
    assert_equal "run_canceled", result.dig("error", "key")
    assert loop_node(current, "r2t0-wait-1").output_summary.fetch("is_error")
    assert_nil call.reload.spawned_conversation
  end

  test "force stop closes the wait and a later target completion cannot revive it" do
    run = start_loop(detached(ask("work")), wait_step("observer", "work"))
    result = Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human))
    assert_predicate result, :accepted?
    assert_equal "canceled", loop_node(run, "observer").status
    Runs::ScheduleSweep.call
    assert_equal "canceled", loop_node(run, "observer").status
  end
end
