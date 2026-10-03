# The `task` executor's process: it settles a parked call and grows the
# graph, which a request path must never do on whichever connection
# scheduled it. The same shape as the compose job.
class AgentLoops::TaskToolJob < ApplicationJob
  def perform(node_id)
    node = AgentLoopNode.find_by(id: node_id)
    return if node.nil?

    AgentLoops::TaskTool::Run.call(node: node)
    AgentLoops::ScheduleJob.perform_later(node.agent_loop_id)
  end
end
