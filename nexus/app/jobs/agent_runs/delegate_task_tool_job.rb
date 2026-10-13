# The `task` executor's process: it settles a parked call and grows the
# graph, which a request path must never do on whichever connection
# scheduled it.
class AgentRuns::DelegateTaskToolJob < ApplicationJob
  def perform(node_id)
    node = AgentRunTask.find_by(id: node_id)
    return if node.nil?

    AgentRuns::DelegateTaskTool::Run.call(node: node)
    AgentRuns::ScheduleJob.perform_later(node.agent_run_id)
  end
end
