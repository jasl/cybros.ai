require_relative "agents/routes"
require_relative "agents/commands"

module Rho
  module Extensions
    # THE NAMED SUB-AGENT DEFINITIONS' VERBS AND ROUTES: `rho agents` lists the two
    # homes — the instance's file definitions as the kernel holds them and
    # the steward's published rows — `sync` runs the declare edge past its
    # tuple, `publish NAME` flips one definition's row to the steward's
    # scope, `rm NAME` removes this instance's row. The DECLARATION itself
    # is the daemon's declare edge (`HostFollowers::NamedDefinitions`), not this
    # extension's: a prelude that drops the extension keeps the roster;
    # the extension keeps the verbs and the routes alone.
    module Agents
      NAME = "rho.agents".freeze

      def self.register(api)
        Routes.register(api)
        api.register_command("agents",
          usage: "agents | agents sync | agents publish NAME | agents rm NAME",
          description: "The named sub-agents this daemon defines from `.agents/agents/*.md` at its root " \
                       "(instance/) and the ones published under the steward (nexus/); sync re-reads the " \
                       "files and declares them, publish NAME persists one in Nexus for every agent of the " \
                       "steward, rm NAME removes this instance's row (the file, if it stays, returns it)",
          &Commands.method(:agents))
      end
    end
  end
end
