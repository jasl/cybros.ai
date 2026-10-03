# The `ask` executor's process: one await placed under the loop lock and
# the call settled, never from a request path. The same shape as the compose job.
class AgentLoops::AskJob < ApplicationJob
  def perform(node_id)
    node = AgentLoopNode.find_by(id: node_id)
    return if node.nil?

    AgentLoops::Asks::Run.call(node: node)
    AgentLoops::ScheduleJob.perform_later(node.agent_loop_id)
  end
end
