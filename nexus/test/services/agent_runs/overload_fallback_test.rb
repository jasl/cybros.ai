require "test_helper"
require "test_helpers/log_capture"
require "test_helpers/refused_step_test_helper"

# A STEP THE PROVIDER WAS OVERLOADED FOR ON EVERY ATTEMPT RE-RUNS ONCE ON THE MODEL ITS ANSWERER
# DECLARED — the refusal's own mechanism with a second trigger. Overload is the provider's load said
# per attempt (503, 529, the streamed `overloaded_error`) and the work's key only when EVERY budgeted
# attempt said it; a rate limit, a gateway error or a timeout is only transient and never switches.
# The switch is once per step and never back to a model that failed it so. Work the step starts
# afterwards — a model branch, a delegated task, the model a spawn names — begins on the model the
# lineage was configured with, never the fallback the mainline moved to.
class AgentRuns::OverloadFallbackTest < ActiveJob::TestCase
  include RefusedStepTestHelper
  include LogCapture

  SWITCH = { "from" => "dev/mock-text", "reason" => "provider_overloaded" }.freeze

  setup do
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @attempts = {}
    declare_tools!(@agent, tools: [READ_TOOL, Nexus::Tools::DELEGATE_TASK],
      default_model: "dev/mock-text", fallback_model: "dev/mock-unmetered")
  end

  test "a mainline round overloaded on every attempt re-runs once on the declared fallback" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
    schedule(agent_run)

    lines = capture_log { overload!(agent_run, "r1") }

    round = node(agent_run, "r1")
    assert_equal ["running", 1, "mock-unmetered"], round.values_at(:status, :execution_generation, :model_ref)
    assert_equal({ "model_change" => SWITCH }, round.output_summary)
    overloaded = step_invocations(round).first
    assert_equal %w[failed provider_overloaded mock-text],
      overloaded.values_at(:status, :failure_reason_key, :model_ref)
    assert_equal [SWITCH.merge("to" => "dev/mock-unmetered")],
      conversation.conversation_event_items.where(item_type: "task_status").order(:sequence)
        .filter_map { |item| item.payload["model_change"] }, "the switch narrates on the turn's feed"
    assert_equal 1, lines.grep(/event=model_fallback .* reason=provider_overloaded/).length
  end

  test "a budget spent on answers that were not all overload stands where it is" do
    agent_run = seed(model("m", "prompt" => "go"), creating_user: @agent)
    start_loop(agent_run)

    overload!(agent_run, "m", statuses: [504, 504, 529])

    step = node(agent_run, "m")
    assert_equal %w[failed attempt_budget_spent mock-text], step.values_at(:status, :error_key, :model_ref)
    assert_nil step.output_summary["model_change"]
  end

  test "a fallback overloaded in turn stands, naming both causes, and nothing runs a third time" do
    agent_run = seed(model("m", "prompt" => "go"), creating_user: @agent)
    start_loop(agent_run)
    overload!(agent_run, "m")
    assert_equal "mock-unmetered", node(agent_run, "m").model_ref

    overload!(agent_run, "m")

    step = node(agent_run, "m")
    assert_equal %w[failed provider_overloaded], step.values_at(:status, :error_key)
    assert_equal "dev/mock-unmetered was overloaded on every attempt of this step, so it failed with no output; " \
                 "it was already re-run once after dev/mock-text was overloaded, so nothing re-ran it again",
      step.error_detail
    assert_equal 2, step_invocations(step).count
  end

  # THE CONFIGURED MODEL OF THE LINEAGE: the mainline moved to the fallback because its model was
  # overloaded, but the work it starts next is new work, and new work begins on the model the step
  # was configured with — the overload was transient; the fallback is the exception.
  test "work a switched round starts begins on the pre-switch model" do
    agent_run = seed(model("round1", "tools" => [Nexus::Tools::DELEGATE_TASK]),
      creating_user: @agent)
    start_loop(agent_run)
    overload!(agent_run, "round1")
    assert_equal "mock-unmetered", node(agent_run, "round1").model_ref

    run_step!(agent_run, "round1", sse_success("composing", tool_calls: [
      { id: "task_call", name: "delegate_task", arguments: {
        prompt: "Review the patch", wait: true,
      }.to_json },
    ]))
    AgentRuns::DelegateTaskToolJob.perform_now(node(agent_run, "r1t0").id)
    schedule(agent_run)

    assert_equal "mock-text", node(agent_run, "r1t0-model-1").model_ref, "a delegated model starts configured"
    assert_equal({ provider_id: "dev", model_ref: "mock-text", reasoning_effort: "medium", reasoning_enabled: true },
      AgentRuns::KernelTool.initiator_model(node(agent_run, "r1t0"), {}),
      "the model a spawn or send names by default is the configured one too")
    assert_equal "mock-unmetered", AgentRuns::CurrentModel.for(agent_run).model_ref,
      "while the mainline itself stays on the fallback for the turn"
  end

  test "a delegated task begins on the pre-switch model" do
    agent_run = seed(model("round1", "tools" => [Nexus::Tools::DELEGATE_TASK]), creating_user: @agent)
    start_loop(agent_run)
    overload!(agent_run, "round1")

    apply_via(step_attempt(agent_run, "round1"), sse_success("delegating", tool_calls: [
      { id: "task_call", name: "delegate_task", arguments: { prompt: "look into it", wait: true }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) { schedule(agent_run) }

    delegate = agent_run.agent_run_tasks.where(expansion_parent_id: node(agent_run, "r1t0").id).sole
    assert_equal "mock-text", delegate.model_ref
  end

  # Only a cause that SWITCHED says where the lineage began: a later round the fallback was overloaded
  # for stood there and re-ran by its own retry budget, so it moved nothing.
  test "a later round the fallback was overloaded for leaves the lineage configured where it began" do
    agent_run = seed(model("round1", "tools" => [READ_TOOL, Nexus::Tools::DELEGATE_TASK], "retry" => 1),
      creating_user: @agent)
    start_loop(agent_run)
    overload!(agent_run, "round1")
    assert_equal "r1", read!(agent_run, "round1").node_key
    assert_equal "mock-unmetered", node(agent_run, "r1").model_ref

    overload!(agent_run, "r1")
    assert_equal ["running", 1, "mock-unmetered"], node(agent_run, "r1").values_at(:status, :execution_generation,
      :model_ref), "the fallback stood and the retry budget re-ran it where it was"

    assert_equal "mock-text", task_branch(agent_run, "r1").model_ref
  end

  # A summary replaces what a round reads, never the lineage it was configured on.
  test "a round after an in-turn compaction still starts work on the pre-switch model" do
    agent_run = seed(model("round1", "tools" => [READ_TOOL, Nexus::Tools::DELEGATE_TASK]), creating_user: @agent)
    start_loop(agent_run)
    overload!(agent_run, "round1")
    read!(agent_run, "round1", schedule: false)
    compacted = AgentRuns::Tasks::Compact.call(AgentRuns::Tasks::Compact::Command.new(
      agent_run: agent_run, task_key: "r1", acting_user: @human
    ))
    assert_predicate compacted, :accepted?
    schedule(agent_run)
    run_step!(agent_run, compacted.summary_task_key, sse_success("the summary"))
    assert_predicate node(agent_run, "r1"), :repaired?
    later = read!(agent_run, "r1")
    assert_equal "mock-unmetered", later.model_ref, "the mainline stays on the fallback for the turn"

    assert_equal "mock-text", task_branch(agent_run, later.node_key).model_ref
  end

  # An author's named model is the configuration: a step put on another model keeps it for the work
  # it starts, and a lineage that moved only because a model was unavailable has nothing to return to.
  test "the configured model is the lineage's own when nothing overloaded or refused it" do
    named = seed(model("m", "model" => { "model" => "dev/mock-windowless" }), creating_user: @agent)
    start_loop(named)

    step = node(named, "m")
    assert_equal({ "model" => "dev/mock-windowless", "reasoning_effort" => step.reasoning_effort }.compact,
      AgentRuns::ConfiguredModel.for(step).model)
  end

  # A LANE THAT NEEDS EVERY TOOL ROUND'S REASONING BACK (DeepSeek with tools, Kimi K3) cannot take a
  # history of tool rounds another model produced: it has no reasoning of theirs to read, and the
  # vendor refuses the request without it. Such a fallback stands, by name, rather than failing at
  # the provider.
  test "a fallback that needs every tool round's reasoning back stands on foreign tool rounds" do
    catalog = ModelCatalog.current
    row = catalog.models.fetch("dev/mock-unmetered")
    keeping = row.merge("capabilities" => row.fetch("capabilities").merge(
      "reasoning_replay" => { "format" => "responses_reasoning", "required_for_tool_rounds" => true }
    ))
    ModelCatalog.stub(:current, catalog.with(models: catalog.models.merge("dev/mock-unmetered" => keeping))) do
      agent_run = seed(model("round1", "tools" => [READ_TOOL]), creating_user: @agent)
      start_loop(agent_run)
      run_step!(agent_run, "round1", sse_success("reading", tool_calls: [
        { id: "call_a", name: "read_file", arguments: { path: "a" }.to_json },
      ]))
      settled = AgentRuns::Parks::Settle.call(node: node(agent_run, "r1t0"), trusted: true,
        content: "contents of a", outcome: "completed")
      assert_predicate settled, :applied?
      schedule(agent_run)

      overload!(agent_run, "r1")

      step = node(agent_run, "r1")
      assert_equal %w[failed provider_overloaded mock-text], step.values_at(:status, :error_key, :model_ref)
      assert_equal "dev/mock-text was overloaded on every attempt of this step, so it failed with no output; " \
                   "the declared fallback model dev/mock-unmetered cannot take this request (foreign_tool_history), " \
                   "so nothing re-ran it",
        step.error_detail
    end
  end

  # Only the TOOL LOOP IN PROGRESS needs its reasoning back: an earlier turn's rounds go back without
  # it (the live check: Kimi K3 and DeepSeek answered 200 with earlier turns' reasoning dropped), so a
  # history whose every call precedes the last user message takes the fallback.
  test "a fallback that needs tool rounds' reasoning back takes a history whose calls are an earlier turn's" do
    replay = Nexus::ReasoningReplayCapability.new(format: "chat_reasoning", required_for_tool_rounds: true)
    selection = Data.define(:capabilities).new(capabilities: Data.define(:reasoning_replay).new(reasoning_replay: replay))
    body = Data.define(:entry_payloads)
    user = { "role" => "user", "parts" => [{ "type" => "text", "text" => "read a" }] }
    call = { "type" => "tool_call_item", "call_id" => "call_a", "name" => "read_file" }
    result = { "type" => "tool_result_item", "call_id" => "call_a" }
    answer = { "role" => "assistant", "parts" => [{ "type" => "text", "text" => "done" }] }

    assert AgentRuns::ModelFallback.takes_tool_history?(selection, body.new([user, call, result, answer, user]))
    refute AgentRuns::ModelFallback.takes_tool_history?(selection, body.new([user, call, result, answer, user, call, result]))
  end

  private

    # The round answers one read, its park settles, and its continuation queues (and starts, unless a
    # case compacts it first): answers the continuation.
    def read!(agent_run, key, schedule: true)
      call_id = "read_#{key}"
      run_step!(agent_run, key, sse_success("reading", tool_calls: [
        { id: call_id, name: "read_file", arguments: { path: "a" }.to_json },
      ]))
      settled = AgentRuns::Parks::Settle.call(node: agent_run.agent_run_tasks.find_by!(tool_call_id: call_id),
        trusted: true, content: "contents of a", outcome: "completed")
      assert_predicate settled, :applied?
      schedule(agent_run) if schedule
      agent_run.agent_run_tasks.where(continuation_source: "round").order(:id).last
    end

    # The round starts one task branch and returns its delegated model.
    def task_branch(agent_run, key)
      call_id = "task_#{key}"
      run_step!(agent_run, key, sse_success("composing", tool_calls: [
        { id: call_id, name: "delegate_task", arguments: {
          prompt: "Review the patch", wait: true,
        }.to_json },
      ]))
      task = agent_run.agent_run_tasks.find_by!(tool_call_id: call_id)
      AgentRuns::DelegateTaskToolJob.perform_now(task.id)
      schedule(agent_run)
      node(agent_run, "#{task.node_key}-model-1")
    end

    # Every budgeted attempt of the step's current execution answers `statuses`, in order; the
    # converger then settles what the budget spent.
    def overload!(agent_run, key, statuses: [529, 529, 529])
      invocation = node(agent_run, key).selected_model_invocation
      statuses.each do |status|
        ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
        apply_via(step_attempt(agent_run, key),
          json_response(status, { "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }))
      end
      converge(agent_run)
    end
end
