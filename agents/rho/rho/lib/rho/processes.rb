require_relative "processes/output"
require_relative "processes/pump"
require_relative "processes/registry"

module Rho
  # THE DAEMON'S PROCESS TABLE: one per daemon, built at boot as host
  # infrastructure and handed to the tools that fill it through
  # `ToolEnv#processes` and to the routes that show it through the
  # extension `Host`. Nothing here is global — a process hosting two
  # daemons holds two tables — and a runner with no daemon holds none.
  module Processes
    class Error < Rho::Error; end
    class Closed < Error; end
    class NotFound < Error; end
    # A group that died and left the table: the exit rides along so a reader can answer with
    # it.
    class Gone < NotFound
      attr_reader :snapshot

      def initialize(message, snapshot:)
        super(message)
        @snapshot = snapshot
      end
    end
    class NotOwner < Error; end
    class Full < Error; end
  end
end
