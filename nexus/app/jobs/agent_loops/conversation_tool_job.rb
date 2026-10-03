# The conversation verbs' process: one job for `spawn`, `send`, `status`
# and `cancel`, dispatching to the registry's executor for the wire word (a
# `Run` service), because each verb grows the graph or opens another
# conversation's door, which a request path must never do on whichever
# connection scheduled it. The same shape as the task and ask jobs; the run
# is idempotent, so a retry resumes.
class AgentLoops::ConversationToolJob < ApplicationJob
  def perform(node_id)
    node = AgentLoopNode.find_by(id: node_id)
    return if node.nil?

    Nexus::ToolRegistry.executor_for(node.tool_name).call(node: node)
    AgentLoops::ScheduleJob.perform_later(node.agent_loop_id)
  end
end
