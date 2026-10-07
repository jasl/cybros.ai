class AgentRuns::ToolDiscoveryJob < ApplicationJob
  def perform(node_id)
    node = AgentRunTask.find_by(id: node_id)
    return if node.nil?

    Nexus::ToolRegistry.executor_for(node.tool_name).call(node: node)
    AgentRuns::ScheduleJob.perform_later(node.agent_run_id)
  end
end
