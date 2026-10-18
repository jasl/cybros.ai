require "test_helper"
require_relative "../../test_helpers/runs_execution_test_helper"

class Runs::ConversationCostLimitTest < ActiveJob::TestCase
  include RunsExecutionTestHelper

  Task::ON_FAILURE_POLICIES.each do |policy|
    test "a cost refusal under #{policy} holds the model and its consumers until explicit retry" do
      run = seed(model("limited", "on_failure" => policy), model("after"))
      start!(run)
      refuse_cost!(run, "limited")

      limited = node(run, "limited")
      assert_equal policy, limited.on_failure, "the accepted declaration remains immutable"
      assert_predicate limited, :unresolved_failure?
      assert_equal :pending, Runs::Graph.settlement_of(limited)
      assert_equal ["needs_attention", "halt_failure"], run.reload.values_at(:status, :attention_reason)
      assert_equal ["queued", 1], node(run, "after").values_at(:status, :remaining_dependencies)
      assert_equal ["failed", "waiting"], AgentAPI::RunPhasesPresenter.call(run).phases.map(&:status)
      assert_equal ["limited"], AgentAPI::RunPresenter.full(run).dig(:attention, :blocked_task_keys)
      assert_equal 0, ModelInvocation.find(limited.selected_model_invocation_id).attempts.count

      # Recount and append consume the same effective policy as quiescence.
      run.with_lock { Runs::Release.recompute(node(run, "after")) }
      assert_equal ["queued", 1], node(run, "after").values_at(:status, :remaining_dependencies)
      appended = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
        run: run, origin: "kernel",
        steps: [Runs::Tasks::Step.inheriting(limited, key: "later", prompt: "continue")],
        tip: kernel_tip(limited, [limited], [], "branch")
      ))
      assert_predicate appended, :applied?
      assert_equal ["queued", 1], node(run, "later").values_at(:status, :remaining_dependencies)

      assert_predicate retry_task(run, "limited"), :accepted?
      schedule!(run)
      run_step!(run, sse_success("repaired"), key: "limited")
      assert_equal "running", node(run, "after").status
      assert_equal "running", node(run, "later").status
      run_step!(run, sse_success("done"), key: "after")
      run_step!(run, sse_success("done too"), key: "later")
      assert_equal "completed", run.reload.status
      assert_equal 1, node(run, "limited").execution_generation
    end
  end

  test "an ordinary model error still follows absorb or propagate and a tool cannot claim the cost refusal" do
    { "absorb" => :resolved, "propagate" => :skip }.each do |policy, settlement|
      run = seed(model("ordinary", "on_failure" => policy), model("after"))
      start!(run)
      run_step!(run, json_response(400, { "error" => "bad" }))
      assert_equal settlement, Runs::Graph.settlement_of(node(run, "ordinary"))
      assert_equal(policy == "absorb" ? "running" : "skipped", node(run, "after").status)
      run_step!(run, sse_success("done")) if policy == "absorb"
    end

    run = seed(tool("external", "shell", "on_failure" => "absorb"), model("after"))
    start!(run)
    run.with_lock do
      Runs::FailNode.call(run: run, node: node(run, "external"),
        error_key: Conversation::COST_LIMIT_REACHED, worklist: [])
    end
    assert_not node(run, "external").unresolved_failure?
    assert_equal :resolved, Runs::Graph.settlement_of(node(run, "external"))
    schedule!(run)
    assert_equal "running", node(run, "after").status
  end

  test "retrying a cost refused model preserves a completed tool and its output" do
    run = seed(tool("effect"), model("limited", "on_failure" => "absorb"), model("after"))
    start!(run)
    result = Runs::Parks::Settle.call(node: node(run, "effect"), trusted: true,
      content: "the effect already completed", is_error: false, outcome: "completed")
    assert_predicate result, :applied?
    effect = node(run, "effect")
    preserved = %w[status execution_generation completed_at output_summary]
    original = effect.attributes.slice(*preserved)
    output_id = effect.output_body.id
    schedule!(run)
    refuse_cost!(run, "limited")
    assert_predicate retry_task(run, "limited"), :accepted?
    schedule!(run)
    run_step!(run, sse_success("continued"), key: "limited")
    run_step!(run, sse_success("done"), key: "after")

    assert_equal "completed", run.reload.status
    assert_equal original, effect.reload.attributes.slice(*preserved)
    assert_equal output_id, effect.output_body.id
    assert_equal "the effect already completed", effect.output_body.effective_text
  end

  test "a settled race absorbs its cost refused loser but an unfinished branch still holds" do
    %w[cancel run_out].each do |losers|
      run = seed(parallel(model("fast"), [model("limited", "on_failure" => "propagate"), model("tail")],
        until: "any", key: "race", losers: losers), model("after"))
      start!(run)
      refuse_cost!(run, "limited")
      assert_equal "running", run.reload.status
      run_step!(run, sse_success("winner"), key: "fast")
      run_step!(run, sse_success("done"), key: "after")

      if losers == "cancel"
        assert_equal "completed", run.reload.status
        assert_equal :resolved, Runs::Graph.settlement_of(node(run, "limited"))
        assert_equal "canceled", node(run, "tail").status
      else
        assert_equal "needs_attention", run.reload.status
        assert_equal :pending, Runs::Graph.settlement_of(node(run, "limited"))
        assert_equal ["queued", 1], node(run, "tail").values_at(:status, :remaining_dependencies)
        assert_predicate retry_task(run, "limited"), :accepted?
        schedule!(run)
        run_step!(run, sse_success("repaired"), key: "limited")
        run_step!(run, sse_success("tail"), key: "tail")
        assert_equal "completed", run.reload.status
      end
    end
  end

  test "Stop wins before application and after a cost refusal holds" do
    [false, true].each do |converged|
      run = seed(model("limited", "on_failure" => "absorb"), model("after"))
      start!(run)
      terminalize_cost!(run, "limited")
      Runs::ConvergeTerminalSteps.call if converged
      assert_predicate Runs::Stop.call(Runs::Stop::Command.forced(run: run, acting_user: @human)), :accepted?
      Runs::ConvergeTerminalSteps.call
      schedule!(run)

      assert_equal "canceled", run.reload.status
      assert_equal "canceled", node(run, "after").status
      assert_equal :not_adjudicable, retry_task(run, "limited").outcome
      assert_equal 0, node(run, "limited").execution_generation
    end
  end

  private

    def terminalize_cost!(run, key)
      invocation = ModelInvocation.find(node(run, key).selected_model_invocation_id)
      invocation.with_lock { invocation.terminalize(status: "failed", reason_key: Conversation::COST_LIMIT_REACHED) }
    end

    def refuse_cost!(run, key)
      terminalize_cost!(run, key)
      Runs::ConvergeTerminalSteps.call
      schedule!(run)
    end

    def retry_task(run, key)
      Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(run: run, task_key: key, acting_user: @human))
    end
end
