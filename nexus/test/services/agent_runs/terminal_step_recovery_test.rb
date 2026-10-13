require "test_helper"

class AgentRuns::TerminalStepRecoveryTest < ActiveJob::TestCase
  include InvocationHarness
  include ActiveSupport::Testing::ConstantStubbing

  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  # A number the row store cannot spell fails that one call with the encoder's sentence; the round
  # is authored around it, never refused and never stranded.
  test "unsupported numeric arguments fail that call instead of stranding a completed invocation" do
    invocation, node = completed_step(tool_calls: [
      { id: "large", name: "read_file", arguments: '{"offset":1e100}' },
      { id: "ordinary", name: "read_file", arguments: '{"offset":1}' },
    ])
    errors = []

    Rails.error.stub(:report, ->(error, **) { errors << error }) do
      3.times { AgentRuns::ConvergeTerminalSteps.call }
    end

    assert_equal "completed", node.reload.status, errors.map(&:message).join("; ")
    assert_not_nil invocation.reload.terminal_event_recorded_at
    assert_empty errors
    large, ordinary = %w[large ordinary].map { |id| node.agent_run.agent_run_tasks.find_by!(tool_call_id: id) }
    assert_equal %w[failed invalid_tool_input], [large.status, large.error_key]
    assert_includes large.error_detail, "encode the value as a string", "the model reads the encoder's repair"
    assert_includes %w[queued dispatched], ordinary.status, "the ordinary call runs"
    AgentRuns::ScheduleReady.call(agent_run_id: node.agent_run_id)
    assert_not_predicate node.agent_run.reload, :needs_attention?
  end

  test "a failed terminal step does not hold healthy results behind the continuation window" do
    retained, = completed_step
    healthy, = completed_step
    apply = AgentRuns::ApplyStepResult.method(:call)
    attempts = []
    reports = []
    failing = ->(agent_run:, invocation:) do
      attempts << invocation.id
      raise IOError, "step application interrupted" if invocation.id == retained.id

      apply.call(agent_run: agent_run, invocation: invocation)
    end

    Rails.error.stub(:report, ->(_error, context:, **) { reports << context }) do
      AgentRuns::ApplyStepResult.stub(:call, failing) do
        stub_const(AgentRuns::ConvergeTerminalStepsJob, :BATCH, 1) do
          arguments = []
          3.times do
            clear_enqueued_jobs
            AgentRuns::ConvergeTerminalStepsJob.perform_now(*arguments)
            continuation = enqueued_jobs.find { |job| job[:job] == AgentRuns::ConvergeTerminalStepsJob }
            break if continuation.nil?

            arguments = continuation.fetch(:args)
          end
          assert_equal [retained.id, healthy.id], attempts,
            "this chain visits each retained result only once"
          AgentRuns::ConvergeTerminalStepsJob.perform_now
        end
      end
    end

    assert_nil retained.reload.terminal_event_recorded_at
    assert_not_nil healthy.reload.terminal_event_recorded_at,
      "the continuation must advance past a retained failure"
    assert_equal [retained.id, healthy.id, retained.id], attempts,
      "the next recurring wake retries the retained row"
    assert_equal Array.new(2) {
      { event: "agent_run_task_converge_failed", invocation_public_id: retained.public_id }
    }, reports
  end

  private

    def completed_step(tool_calls: [])
      agent_run = seed(model("round", "tools" => [READ_TOOL]))
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      node = agent_run.agent_run_tasks.find_by!(node_key: "round")
      attempt = ModelInvocations::AdmitQueuedWork.call.admitted
        .find { |candidate| candidate.attempt.model_invocation_id == node.selected_model_invocation_id }.attempt
      apply_via(attempt, sse_success("answer", tool_calls: tool_calls))
      invocation = attempt.model_invocation.reload
      assert_predicate invocation, :completed?
      clear_enqueued_jobs
      [invocation, node]
    end
end
