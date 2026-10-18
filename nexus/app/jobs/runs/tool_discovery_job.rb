class Runs::ToolDiscoveryJob < ApplicationJob
  def perform(node_id)
    node = Task.find_by(id: node_id)
    return if node.nil?

    Nexus::ToolRegistry.executor_for(node.tool_name).call(node: node)
    Runs::ScheduleJob.perform_later(node.run_id)
  end
end
