# The kernel mail's process: the quiescence site runs under the loop lock
# and the input door takes the conversation lock, so a settled orphan is
# mailed after commit, never inside the pass. ScheduleSweep rediscovers
# unmailed tips, including a refused attempt.
class AgentRuns::ResultDeliveryJob < ApplicationJob
  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return if agent_run.nil? || agent_run.standalone?

    AgentRuns::ResultDelivery.call(agent_run)
  end
end
