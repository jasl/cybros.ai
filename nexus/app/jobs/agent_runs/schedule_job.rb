# The graph's advance wake. Level-triggered: the scheduler re-reads
# readiness under the loop lock, so a duplicate kick is never a double start.
class AgentRuns::ScheduleJob < ApplicationJob
  def perform(agent_run_id)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run_id)
  end
end
