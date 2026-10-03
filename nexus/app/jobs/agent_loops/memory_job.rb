# Not high-consumption, but it settles a parked task, and settling from a
# request path would tie a tool call to whichever connection scheduled it.
class AgentLoops::MemoryJob < ApplicationJob
  def perform(node_id)
    node = AgentLoopNode.find_by(id: node_id)
    return if node.nil?

    AgentLoops::Memory::Run.call(node: node)
    AgentLoops::ScheduleJob.perform_later(node.agent_loop_id)
  end
end
