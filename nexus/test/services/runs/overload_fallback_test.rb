require "test_helper"
require "test_helpers/log_capture"
require "test_helpers/refused_step_test_helper"

# Exhausting a route's transient attempt allowance advances through the captured
# fallback order. A homogeneous overload keeps its precise failure key. Work
# started by a switched round retains the lineage's configured model.
class Runs::OverloadFallbackTest < ActiveJob::TestCase
  include RefusedStepTestHelper
  include LogCapture

  SWITCH = { "from" => "dev/mock-text", "reason" => "provider_overloaded" }.freeze

  setup do
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @attempts = {}
    declare_tools!(@agent, tools: [READ_TOOL, Nexus::Tools::DELEGATE_TASK],
      default_model: "dev/mock-text", fallback_models: ["dev/mock-unmetered"])
  end

  test "a mainline round overloaded on every attempt re-runs once on the declared fallback" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, run = materialize_loop_reply!(conversation, agent: @agent)
    schedule(run)

    lines = capture_log { overload!(run, "r1") }

    round = node(run, "r1")
    assert_equal ["running", 1, "mock-unmetered"], round.values_at(:status, :execution_generation, :model_ref)
    assert_equal({ "model_change" => SWITCH }, round.output_summary)
    overloaded = step_invocations(round).first
    assert_equal %w[failed provider_overloaded mock-text],
      overloaded.values_at(:status, :failure_reason_key, :model_ref)
    assert_equal [SWITCH.merge("to" => "dev/mock-unmetered")],
      conversation.event_items.where(item_type: "task_status").order(:sequence)
        .filter_map { |item| item.payload["model_change"] }, "the switch narrates on the turn's feed"
    assert_equal 1, lines.grep(/event=model_fallback .* reason=provider_overloaded/).length
  end

  test "a mixed transient budget advances after the existing route attempts are exhausted" do
    run = seed(model("m", "prompt" => "go"), creating_user: @agent)
    start_loop(run)

    overload!(run, "m", statuses: [504, 504, 529])

    step = node(run, "m")
    assert_equal %w[running mock-unmetered], step.values_at(:status, :model_ref)
    assert_equal "provider_transient_exhausted", step_invocations(step).first.failure_reason_key
    assert_equal 3, step_invocations(step).first.attempts.count
    assert_equal "provider_transient_exhausted", step.output_summary.dig("model_change", "reason")
  end

  test "a fallback overloaded in turn stands, naming both causes, and nothing runs a third time" do
    run = seed(model("m", "prompt" => "go"), creating_user: @agent)
    start_loop(run)
    overload!(run, "m")
    assert_equal "mock-unmetered", node(run, "m").model_ref

    overload!(run, "m")

    step = node(run, "m")
    assert_equal %w[failed provider_overloaded], step.values_at(:status, :error_key)
    assert_equal "dev/mock-unmetered was overloaded on every attempt of this step, so it failed with no output; " \
                 "no remaining configured fallback can take this request (no_selectable_fallback), so nothing re-ran it",
      step.error_detail
    assert_equal 2, step_invocations(step).count
  end

  # THE CONFIGURED MODEL OF THE LINEAGE: the mainline moved to the fallback because its model was
  # overloaded, but the work it starts next is new work, and new work begins on the model the step
  # was configured with — the overload was transient; the fallback is the exception.
  test "work a switched round starts begins on the pre-switch model" do
    run = seed(model("round1", "tools" => [Nexus::Tools::DELEGATE_TASK]),
      creating_user: @agent)
    start_loop(run)
    overload!(run, "round1")
    assert_equal "mock-unmetered", node(run, "round1").model_ref

    run_step!(run, "round1", sse_success("composing", tool_calls: [
      { id: "task_call", name: "delegate_task", arguments: {
        prompt: "Review the patch", wait: true,
      }.to_json },
    ]))
    Runs::DelegateTaskToolJob.perform_now(node(run, "r1t0").id)
    schedule(run)

    assert_equal "mock-text", node(run, "r1t0-model-1").model_ref, "a delegated model starts configured"
    assert_equal({ provider_id: "dev", model_ref: "mock-text", reasoning_effort: "medium", reasoning_enabled: true },
      Runs::KernelTool.initiator_model(node(run, "r1t0"), {}),
      "the model a spawn or send names by default is the configured one too")
    assert_equal "mock-unmetered", Runs::CurrentModel.for(run).model_ref,
      "while the mainline itself stays on the fallback for the turn"
  end

  test "a delegated task begins on the pre-switch model" do
    run = seed(model("round1", "tools" => [Nexus::Tools::DELEGATE_TASK]), creating_user: @agent)
    start_loop(run)
    overload!(run, "round1")

    apply_via(step_attempt(run, "round1"), sse_success("delegating", tool_calls: [
      { id: "task_call", name: "delegate_task", arguments: { prompt: "look into it", wait: true }.to_json },
    ]))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [Runs::DelegateTaskToolJob, Runs::ScheduleJob]) { schedule(run) }

    delegate = run.tasks.where(expansion_parent_id: node(run, "r1t0").id).sole
    assert_equal "mock-text", delegate.model_ref
  end

  # A later round that exhausts the fallback's allowance does not move the
  # lineage's original configured model.
  test "a later round the fallback was overloaded for leaves the lineage configured where it began" do
    run = seed(model("round1", "tools" => [READ_TOOL, Nexus::Tools::DELEGATE_TASK]),
      creating_user: @agent)
    start_loop(run)
    overload!(run, "round1")
    assert_equal "r1", read!(run, "round1").node_key
    assert_equal "mock-unmetered", node(run, "r1").model_ref

    overload!(run, "r1")
    assert_equal ["failed", 0, "mock-unmetered"], node(run, "r1").values_at(:status, :execution_generation,
      :model_ref), "the spent route does not mint another invocation"

    assert_equal "mock-text", Runs::ConfiguredModel.for(node(run, "r1")).model_ref
  end

  # A summary replaces what a round reads, never the lineage it was configured on.
  test "a round after an in-turn compaction still starts work on the pre-switch model" do
    run = seed(model("round1", "tools" => [READ_TOOL, Nexus::Tools::DELEGATE_TASK]), creating_user: @agent)
    start_loop(run)
    overload!(run, "round1")
    read!(run, "round1", schedule: false)
    compacted = Runs::Tasks::Compact.call(Runs::Tasks::Compact::Command.new(
      run: run, task_key: "r1", acting_user: @human
    ))
    assert_predicate compacted, :accepted?
    schedule(run)
    run_step!(run, compacted.summary_task_key, sse_success("the summary"))
    assert_predicate node(run, "r1"), :repaired?
    later = read!(run, "r1")
    assert_equal "mock-unmetered", later.model_ref, "the mainline stays on the fallback for the turn"

    assert_equal "mock-text", task_branch(run, later.node_key).model_ref
  end

  # An author's named model is the configuration: a step put on another model keeps it for the work
  # it starts, and a lineage that moved only because a model was unavailable has nothing to return to.
  test "the configured model is the lineage's own when nothing overloaded or refused it" do
    named = seed(model("m", "model" => { "model" => "dev/mock-windowless" }), creating_user: @agent)
    start_loop(named)

    step = node(named, "m")
    assert_equal({ "model" => "dev/mock-windowless", "reasoning_effort" => step.reasoning_effort }.compact,
      Runs::ConfiguredModel.for(step).model)
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
      run = seed(model("round1", "tools" => [READ_TOOL]), creating_user: @agent)
      start_loop(run)
      run_step!(run, "round1", sse_success("reading", tool_calls: [
        { id: "call_a", name: "read_file", arguments: { path: "a" }.to_json },
      ]))
      settled = Runs::Parks::Settle.call(node: node(run, "r1t0"), trusted: true,
        content: "contents of a", outcome: "completed")
      assert_predicate settled, :applied?
      schedule(run)

      overload!(run, "r1")

      step = node(run, "r1")
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

    assert Runs::ModelFallback.takes_tool_history?(selection, body.new([user, call, result, answer, user]))
    refute Runs::ModelFallback.takes_tool_history?(selection, body.new([user, call, result, answer, user, call, result]))
  end

  private

    # The round answers one read, its park settles, and its continuation queues (and starts, unless a
    # case compacts it first): answers the continuation.
    def read!(run, key, schedule: true)
      call_id = "read_#{key}"
      run_step!(run, key, sse_success("reading", tool_calls: [
        { id: call_id, name: "read_file", arguments: { path: "a" }.to_json },
      ]))
      settled = Runs::Parks::Settle.call(node: run.tasks.find_by!(tool_call_id: call_id),
        trusted: true, content: "contents of a", outcome: "completed")
      assert_predicate settled, :applied?
      schedule(run) if schedule
      run.tasks.where(continuation_source: "round").order(:id).last
    end

    # The round starts one task branch and returns its delegated model.
    def task_branch(run, key)
      call_id = "task_#{key}"
      run_step!(run, key, sse_success("composing", tool_calls: [
        { id: call_id, name: "delegate_task", arguments: {
          prompt: "Review the patch", wait: true,
        }.to_json },
      ]))
      task = run.tasks.find_by!(tool_call_id: call_id)
      Runs::DelegateTaskToolJob.perform_now(task.id)
      schedule(run)
      node(run, "#{task.node_key}-model-1")
    end

    # Every budgeted attempt of the step's current execution answers `statuses`, in order; the
    # converger then settles what the budget spent.
    def overload!(run, key, statuses: [529, 529, 529])
      invocation = node(run, key).selected_model_invocation
      statuses.each do |status|
        ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
        apply_via(step_attempt(run, key),
          json_response(status, { "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }))
      end
      converge(run)
    end
end
