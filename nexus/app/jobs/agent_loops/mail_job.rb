# The kernel mail's process: the quiescence site runs under the loop lock
# and the input door takes the conversation lock, so a settled orphan is
# mailed after commit, never inside the pass. ScheduleSweep rediscovers
# unmailed tips, including a refused attempt.
class AgentLoops::MailJob < ApplicationJob
  def perform(agent_loop_id)
    agent_loop = AgentLoop.find_by(id: agent_loop_id)
    return if agent_loop.nil? || agent_loop.standalone?

    AgentLoops::Mail.call(agent_loop)
  end
end
