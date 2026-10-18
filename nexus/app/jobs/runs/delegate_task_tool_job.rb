# The `task` executor's process: it settles a parked call and grows the
# graph, which a request path must never do on whichever connection
# scheduled it.
class Runs::DelegateTaskToolJob < ApplicationJob
  def perform(node_id)
    node = Task.find_by(id: node_id)
    return if node.nil?

    Runs::DelegateTaskTool::Run.call(node: node)
    Runs::ScheduleJob.perform_later(node.run_id)
  end
end
