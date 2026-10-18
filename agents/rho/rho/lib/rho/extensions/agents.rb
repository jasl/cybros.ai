require_relative "agents/routes"
require_relative "agents/commands"
require_relative "agents/documents"
require_relative "agents/presets"

module Rho
  module Extensions
    # Bot identities and reusable Presets have separate authoring doors.
    module Agents
      NAME = "rho.agents".freeze

      def self.register(api)
        Routes.register(api)
        Documents.register(api)
        Presets.register(api)
        api.register_command("agents", usage: "agents | agents duplicate SOURCE NAME [owner|external] | agents rm NAME",
          description: "List, duplicate or remove persistent Bot identities", &Commands.method(:agents))
        api.register_command("bots", usage: "bots current BOT | bots new BOT | bots resume BOT CONVERSATION_ID | bots history BOT",
          description: "Open, switch or list a Bot's conversations",
          options: { "operation-id": { type: :string, desc: "Reuse this id to retry a conversation switch" },
                     workspace: { type: :string, desc: "The resumed conversation's recorded Workspace UUID" },
                     after: { type: :string, desc: "Continue Bot history after this cursor" },
                     limit: { type: :numeric, desc: "Maximum number of Bot history rows" } },
          &Commands.method(:bots))
        api.register_command("presets", usage: "presets | presets import [NAME...] | presets import-file FILE | presets export PUBLIC_ID [md|json] | presets duplicate PUBLIC_ID NAME | presets rm PUBLIC_ID",
          description: "List, import, export, duplicate or remove reusable Agent configuration", &Commands.method(:presets))
      end
    end
  end
end
