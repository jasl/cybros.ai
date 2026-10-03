class AgentLoops::ScriptJob < ApplicationJob
  def perform(node_id, generation)
    node = AgentLoopNode.find_by(id: node_id)
    return if node.nil?

    AgentLoops::Scripts::Run.call(node: node, generation: generation)
  end
end
