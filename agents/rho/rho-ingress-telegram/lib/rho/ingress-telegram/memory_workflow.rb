require "rho/memory_commands"

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
        if action.writing? && !owner?(update) && route.fetch("owner_id") != update.user_id
          return "Only this conversation's requester or the bot owner can change its memory."
        end

        workspace_id = workspace_for(route, id)
        ensure_memory_binding(update, route, id, workspace_id)
        operation = -> { @bridge.memory(id, action: action, workspace_public_id: workspace_id) }
        action.writing? ? control(&operation) : operation.call
      end

      private

        def memory_context(update, route, workspace_id)
          owner = @access.owner?(route.fetch("owner_id"))
          return nil if !update.group? && owner

          bindings = [{ "name" => "conversation", "scope" => "conversation", "access" => "read_write" }]
          if update.group?
            anchor = group_memory_anchor(update, workspace_id)
            bindings << { "name" => "group", "scope" => "conversation", "conversation_public_id" => anchor,
              "access" => owner ? "read_write" : "read" }
          else
            anchor = personal_memory_anchor(update, route.fetch("owner_id"), workspace_id)
            bindings << { "name" => "person", "scope" => "conversation", "conversation_public_id" => anchor, "access" => "read_write" }
          end
          { "bindings" => bindings }
        end

        def ensure_memory_binding(update, route, conversation_id, workspace_id)
          tracker = route.fetch("conversations").fetch(conversation_id)
          return if tracker["memory_bound"]

          context = memory_context(update, route, workspace_id)
          @bridge.bind_memory(conversation_id, memory_context: context, workspace_public_id: workspace_id) if context
          @state.change do |document|
            document.fetch("routes").fetch(update.route_key).fetch("conversations").fetch(conversation_id)["memory_bound"] = true
          end
        end

        def group_memory_anchor(update, workspace_id)
          room = @state.read.fetch("rooms")[update.room_key] || {}
          existing = room.fetch("memory_conversations", {})[workspace_id]
          return existing if existing

          id = @bridge.open_memory_anchor(idempotency_key: update_key(update, "memory-group:#{workspace_id}"),
            title: "Telegram group #{update.room_key} memory", workspace_public_id: workspace_id)
          @state.change do |document|
            saved = document.fetch("rooms")[update.room_key] ||= {}
            (saved["memory_conversations"] ||= {})[workspace_id] = id
          end
          id
        end

        def personal_memory_anchor(update, user_id, workspace_id)
          key = "#{workspace_id}:#{user_id}"
          existing = @state.read.fetch("memory_people", {})[key]
          return existing if existing

          id = @bridge.open_memory_anchor(idempotency_key: update_key(update, "memory-person:#{key}"),
            title: "Telegram person #{user_id} memory", workspace_public_id: workspace_id)
          @state.change { |document| (document["memory_people"] ||= {})[key] = id }
          id
        end
    end
  end
end
