require_relative "default_runner/routes"
require_relative "default_runner/commands"

module Rho
  module Extensions
    # Runner discovery, settings selection and nullable host defaults.
    module DefaultRunner
      NAME = "rho.default_runner".freeze

      def self.register(api)
        Routes.register(api)
        register_commands(api)
      end

      def self.register_commands(api)
        api.register_command("runners", usage: "runners [use] [ID]",
          description: "List the runners this profile may address (`use ID` selects one for new conversations, " \
                       "--none clears the selection)",
          options: { none: { type: :boolean, default: false,
                             desc: "Clear the selection: new conversations start on this machine's own runner" } },
          &Commands.method(:runners))
        api.register_command("set_default_runner", usage: "set_default_runner HOST_ID EXECUTOR_ID",
          description: "Set the Runner used for future unqualified tool calls; use none to clear it",
          &Commands.method(:set_default_runner))
      end
    end
  end
end
