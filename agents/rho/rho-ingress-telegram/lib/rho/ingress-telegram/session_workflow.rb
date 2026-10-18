module Rho
  module IngressTelegram
    # Core owns selection and the complete Bot history. Adapter trackers own only
    # original delivery cursors and never write a competing current pointer.
    module SessionWorkflow
      SESSION_PAGE_SIZE = 10

      def session_list(update, argument)
        value = argument.strip
        unless value.empty? || (value.length <= 8 && /\A[1-9][0-9]*\z/.match?(value))
          return "Use /sessions [PAGE] with a positive page number."
        end
        page = value.empty? ? 1 : value.to_i
        cursors = room(update).fetch("session_pages", { "1" => nil })
        unless page == 1 || cursors.key?(page.to_s)
          return "That page has not been listed yet. Use /sessions and follow its next page."
        end
        result = @bridge.bot_history(after: page == 1 ? nil : cursors.fetch(page.to_s), limit: SESSION_PAGE_SIZE)
        current = @bridge.bot_detail["current"]&.fetch("public_id")
        rows = result.fetch("conversations")
        return "No conversations are saved for this Bot. Send a message or use /new to start one." if rows.empty?

        next_after = result.fetch("pagination")["next_after"]
        edit_room(update) do |saved|
          pages = saved["session_pages"] ||= { "1" => nil }
          pages[(page + 1).to_s] = next_after if next_after
          saved["session_locators"] = rows.to_h { |row| [row.fetch("public_id"), row.fetch("workspace_public_id")] }
        end
        text = "Bot conversations (page #{page}):\n#{rows.map { |row| session_label(row, current: current == row.fetch("public_id")) }.join("\n\n")}\n\n" \
          "The bot owner can use /resume ID to select a conversation."
        text += "\nNext page: /sessions #{page + 1}" if next_after
        text
      end

      def resume_session(update, argument)
        return "Only the bot owner can switch the shared conversation." unless owner?(update)

        id = argument.strip
        return "Use /resume ID with the exact conversation ID from /sessions." if id.empty?

        route = room(update)
        workspace_id = route.fetch("session_locators", {})[id] || route.fetch("conversations").dig(id, "workspace_public_id")
        return "Use /sessions to list this conversation before resuming it." unless workspace_id

        result = @bridge.resume_bot_conversation(operation_id: update_key(update, "resume"),
          conversation_public_id: id, workspace_public_id: workspace_id)
        selected = result.fetch("selected")
        track_conversation(update, selected)
        discard_pending_inputs(update.route_key)
        text = "Resumed conversation #{selected.fetch("public_id")}. Earlier work still reports to its original conversation."
        @state.change do |document|
          document.fetch("pending_update").merge!("conversation_id" => selected.fetch("public_id"),
            "workspace_public_id" => selected.fetch("workspace_public_id"), "control_status" => "applied", "control_result" => text)
        end
        text
      rescue Rho::Core::Refused => error
        raise unless [403, 404, 409, 422].include?(error.status)

        "This conversation cannot be resumed for this Bot. Use /sessions to choose another, or /new to start one."
      end

      private

        def session_label(conversation, current:)
          title = Render.preview(conversation["title"].to_s.gsub(/\s+/, " ").strip, limit: 120)
          title = "Untitled conversation" if title.empty?
          title += " [current]" if current
          title += " [archived]" if conversation["archived_at"]
          "#{title}\n#{conversation.fetch("public_id")}"
        end
    end
  end
end
