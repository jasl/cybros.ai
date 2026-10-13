module AgentRunsExecutionTestHelper
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

  def start!(agent_run)
    result = AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  # Admission admits EVERYTHING queued at once, so a parallel fan's
  # attempts all arrive in one pass — cache them and answer per node
  # (matched through the node's own invocation pointer, never by luck).
  def step_attempt(agent_run, key: nil)
    @admitted_attempts ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted_attempts[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    node = key ? node(agent_run, key) : running_model_node(agent_run)
    @admitted_attempts.fetch(node.selected_model_invocation_id) do
      raise "step not admitted for #{node.node_key}"
    end
  end

  def running_model_node(agent_run)
    agent_run.agent_run_tasks
      .where(status: "running").where.not(selected_model_invocation_id: nil).sole
  end

  # One full step: admit the queued step invocation, run it against the
  # fake adapter, converge the terminal, wake the scheduler.
  def run_step!(agent_run, behaviour, key: nil)
    apply_via(step_attempt(agent_run, key: key), behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)
end
