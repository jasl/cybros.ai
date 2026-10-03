# The compose executor's process. A model-authored script is evaluated
# HERE and never in a request path: it is high-consumption work, and a
# job is where high-consumption work is safe to fail.
class AgentLoops::ComposeJob < ApplicationJob
  def perform(node_id)
    node = AgentLoopNode.find_by(id: node_id)
    return if node.nil?

    AgentLoops::Compose::Run.call(node: node)
    AgentLoops::ScheduleJob.perform_later(node.agent_loop_id)
  end
end
