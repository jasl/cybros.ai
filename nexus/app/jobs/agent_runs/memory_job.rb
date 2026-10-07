# Not high-consumption, but it settles a parked task, and settling from a
# request path would tie a tool call to whichever connection scheduled it.
class AgentRuns::MemoryJob < ApplicationJob
  def perform(node_id)
    node = AgentRunTask.find_by(id: node_id)
    return if node.nil?

    AgentRuns::Memory::Run.call(node: node)
    AgentRuns::ScheduleJob.perform_later(node.agent_run_id)
  end
end
