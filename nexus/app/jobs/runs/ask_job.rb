# The `ask` executor's process: one await placed under the loop lock and
# the call settled, never from a request path.
class Runs::AskJob < ApplicationJob
  def perform(node_id)
    node = Task.find_by(id: node_id)
    return if node.nil?

    Runs::Asks::Run.call(node: node)
    Runs::ScheduleJob.perform_later(node.run_id)
  end
end
