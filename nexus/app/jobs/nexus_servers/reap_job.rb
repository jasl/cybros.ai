# The minute prune of Nexus server rows dead for an hour: presence's own
# housekeeping, not a reader of it — a dead row already reads offline the
# moment its heartbeat lapses; this only bounds the table.
class NexusServers::ReapJob < ApplicationJob
  def perform
    NexusServer.reap_dead
  end
end
