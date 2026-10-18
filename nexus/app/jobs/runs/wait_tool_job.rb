class Runs::WaitToolJob < ApplicationJob
  def perform(node_id)
    node = Task.find_by(id: node_id)
    Runs::WaitTool::Run.call(node: node) if node
  end
end
