# The graph's advance wake. Level-triggered: the scheduler re-reads
# readiness under the loop lock, so a duplicate kick is never a double start.
class AgentLoops::ScheduleJob < ApplicationJob
  def perform(agent_loop_id)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop_id)
  end
end
