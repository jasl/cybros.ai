class AgentLoops::WaitToolJob < ApplicationJob
  def perform(node_id)
    node = AgentLoopNode.find_by(id: node_id)
    AgentLoops::WaitTool::Run.call(node: node) if node
  end
end
