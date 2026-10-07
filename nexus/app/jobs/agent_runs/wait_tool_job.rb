class AgentRuns::WaitToolJob < ApplicationJob
  def perform(node_id)
    node = AgentRunTask.find_by(id: node_id)
    AgentRuns::WaitTool::Run.call(node: node) if node
  end
end
