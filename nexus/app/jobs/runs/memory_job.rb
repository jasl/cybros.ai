# Not high-consumption, but it settles a parked task, and settling from a
# request path would tie a tool call to whichever connection scheduled it.
class Runs::MemoryJob < ApplicationJob
  def perform(node_id)
    node = Task.find_by(id: node_id)
    return if node.nil?

    Runs::Memory::Run.call(node: node)
    Runs::ScheduleJob.perform_later(node.run_id)
  end
end
