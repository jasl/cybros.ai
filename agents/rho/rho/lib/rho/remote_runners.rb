require "monitor"

module Rho
  # THE RUNNERS ELSEWHERE THIS DAEMON KNOWS: each discovery
  # document as it was last read — the announced list a turn's declaration
  # is authored from, the announced snapshot its lead renders, the
  # presence word a slot prints — keyed by public id, for the daemon's
  # life. Refreshed by `GET /runners`, `POST /handoff`, a `runner_bound`
  # follow and on a miss; never by a clock. A stale entry costs a wrong
  # sentence in a lead, never a wrong effect: the tools run where the
  # runner is. Owned by `Daemon::Loops`; reached through the facade.
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
