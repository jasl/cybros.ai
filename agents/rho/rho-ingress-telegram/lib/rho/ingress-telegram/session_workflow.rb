module Rho
  module IngressTelegram
    # Routes already remember every conversation whose work reports here. Session
    # selection changes the current pointer without resetting those delivery cursors.
    module SessionWorkflow
      SESSION_PAGE_SIZE = 10

      def session_list(update, argument)
        value = argument.strip
        unless value.empty? || (value.length <= 8 && /\A[1-9][0-9]*\z/.match?(value))
          return "Use /sessions [PAGE] with a positive page number."
        end

        page = value.empty? ? 1 : value.to_i
        route = room(update)
        entries = route.fetch("conversations").to_a.reverse
        return "No conversations are saved in this chat/topic. Send a message or use /new to start one." if entries.empty?

        pages = (entries.length + SESSION_PAGE_SIZE - 1) / SESSION_PAGE_SIZE
        return "That page is not available. Use /sessions with a page from 1 to #{pages}." if page > pages

        rows = entries.slice((page - 1) * SESSION_PAGE_SIZE, SESSION_PAGE_SIZE).map do |id, tracker|
          session_label(id, tracker, current: route["current"] == id)
        end
        "Sessions in this chat/topic (page #{page} of #{pages}):\n#{rows.join("\n\n")}\n\n" \
          "Use /resume ID to continue a conversation from this chat/topic."
      end

      def resume_session(update, argument)
        id = argument.strip
        return "Use /resume ID with the exact conversation ID from /sessions." if id.empty?

        route = room(update)
        tracker = route.fetch("conversations")[id]
        unless tracker
          return "That conversation is not available in this chat/topic. Use /sessions to choose one."
        end

        workspace_id = tracker.fetch("workspace_public_id")
        conversation = @bridge.conversation(id, workspace_public_id: workspace_id)
        if conversation["archived_at"]
          return "This conversation is archived. Use /restore #{id}, then /resume #{id}, or use /new to start another conversation."
        end

        # Following is idempotent. A lost attach reply retries this exact saved
        # source and workspace; it must not freeze an ambiguous Stop-style control.
        @bridge.attach(id, workspace_public_id: workspace_id)
        discard_media(update.route_key)
        text = "Resumed conversation #{id}. Earlier work still reports back here."
        @state.change do |document|
          saved = document.fetch("routes").fetch(update.route_key)
          unless saved.fetch("conversations").key?(id)
            raise Rho::Error, "That conversation is no longer available in this chat/topic. Use /sessions to choose one."
          end

          saved.merge!("current" => id, "workspace_public_id" => workspace_id)
          # Publishing the selection and completed control together lets recovery
          # acknowledge it without selecting it again after a later route change.
          document.fetch("pending_update").merge!("conversation_id" => id,
            "control_status" => "applied", "control_result" => text)
        end
        text
      rescue Rho::Core::Refused => error
        raise unless [403, 404].include?(error.status)

        "This conversation is no longer readable. Use /sessions to choose another, or /new to start one."
      end

      private

        def session_label(id, tracker, current:)
          conversation = @bridge.conversation(id, workspace_public_id: tracker.fetch("workspace_public_id"))
          title = Render.preview(conversation["title"].to_s.gsub(/\s+/, " ").strip, limit: 120)
          title = "Untitled conversation" if title.empty?
          title += " [current]" if current
          title += " [archived]" if conversation["archived_at"]
          "#{title}\n#{id}"
        rescue Rho::Core::Refused => error
          raise unless [403, 404].include?(error.status)

          "Unavailable#{current ? " [current]" : ""}\n#{id}"
        end
    end
  end
end
