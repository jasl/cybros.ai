require "rho/memory_commands"
require "rho/speakers"

module Rho
  module IngressTelegram
    # Logical names select existing database scopes. No memory files, channel
    # copies or implicit Nexus Human accounts are created for external people.
    module MemoryWorkflow
      def memory_command(update, argument)
        action = Rho::MemoryCommands.parse(argument)
        route = room(update)
        id = route["current"]
        return "No conversation is open. Send a message first, then use /memory." unless id
        workspace_id = workspace_for(route, id)
        operation = -> { @bridge.memory(id, action: action, workspace_public_id: workspace_id, speaker_public_id: speaker_for(update)) }
        action.writing? ? control(&operation) : operation.call
      end
    end
  end
end
