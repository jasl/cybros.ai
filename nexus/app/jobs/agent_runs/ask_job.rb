# The `ask` executor's process: one await placed under the loop lock and
# the call settled, never from a request path.
class AgentRuns::AskJob < ApplicationJob
  def perform(node_id)
    node = AgentRunTask.find_by(id: node_id)
    return if node.nil?

    AgentRuns::Asks::Run.call(node: node)
    AgentRuns::ScheduleJob.perform_later(node.agent_run_id)
  end
end
