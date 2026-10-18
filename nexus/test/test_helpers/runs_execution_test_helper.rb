module RunsExecutionTestHelper
  extend ActiveSupport::Concern
  include InvocationHarness

  included do
    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      @workspace = workspaces(:shared)
      DevModelLane.ensure_enabled!(@account)
    end
  end

  def start!(run)
    result = Runs::Start.call(Runs::Start::Command.new(
      run: run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    clear_enqueued_jobs
    schedule!(run)
  end

  def schedule!(run)
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
  end

  # Admission admits EVERYTHING queued at once, so a parallel fan's
  # attempts all arrive in one pass — cache them and answer per node
  # (matched through the node's own invocation pointer, never by luck).
  def step_attempt(run, key: nil)
    @admitted_attempts ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted_attempts[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    node = key ? node(run, key) : running_model_node(run)
    @admitted_attempts.fetch(node.selected_model_invocation_id) do
      raise "step not admitted for #{node.node_key}"
    end
  end

  def running_model_node(run)
    run.tasks
      .where(status: "running").where.not(selected_model_invocation_id: nil).sole
  end

  # One full step: admit the queued step invocation, run it against the
  # fake adapter, converge the terminal, wake the scheduler.
  def run_step!(run, behaviour, key: nil)
    apply_via(step_attempt(run, key: key), behaviour)
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
  end

  def node(run, key) = run.tasks.find_by!(node_key: key)
end
