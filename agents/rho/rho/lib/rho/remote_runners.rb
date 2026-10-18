require "monitor"

module Rho
  # THE RUNNERS ELSEWHERE THIS DAEMON KNOWS: each discovery
  # document as it was last read — operator inspection and application
  # policy facts, the announced snapshot used for root overrides, the
  # presence word a slot prints — keyed by public id, for the daemon's
  # life. Refreshed by `GET /runners`, `POST /default_runner`, a `default_runner_changed`
  # follow and on a miss; never by a clock. A stale entry costs a wrong
  # sentence in an inspection, never tool authority: the complete candidate
  # discovery and Nexus assembly decide each new work item's tools. Owned by `Daemon::HostFollowers`; reached through the facade.
  class RemoteRunners
    def initialize
      @documents = {}
      @monitor = Monitor.new
    end

    def get(public_id) = @monitor.synchronize { @documents[public_id] }

    def put(document)
      @monitor.synchronize { @documents[document.public_id] = document }
      document
    end

    def delete(public_id) = @monitor.synchronize { @documents.delete(public_id) }

    def ids = @monitor.synchronize { @documents.keys }
  end
end
