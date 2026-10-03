module Rho
  module IngressTelegram
    # Side conversations reuse rho's existing fork and follower. The channel keeps
    # only the destination and accepted-input identity beside its ordinary routes.
    module SideWorkflow
      def side_question(update, text)
        if update.media || update.unsupported_media?
          raise Rho::Error, "/btw accepts text only. Send attachments as a normal queued message."
        end
        parent_id = open_route(update)
        workspace_id = workspace_for(room(update), parent_id)
        pending = @state.read.fetch("pending_update")
        side_id = pending["side_conversation_id"] || @bridge.open_side(parent: parent_id)
        @state.change do |document|
          document.fetch("pending_update")["side_conversation_id"] = side_id
          route = document.fetch("routes").fetch(update.route_key)
          route.fetch("conversations")[side_id] ||= {
            "position" => nil, "workspace_public_id" => workspace_id, "side_parent" => parent_id,
          }
        end
        # Core can reuse a side created before this parent's memory was bound.
        # Apply the same roots before admitting another input on that side.
        ensure_memory_binding(update, room(update), side_id, workspace_id)
        key = prepare_request(update, side_id, purpose: "side-input")
        fields = { side: true, tool_names: input_tool_names(user_id: update.user_id, group: update.group?,
          route_key: update.route_key, conversation_id: side_id) }.compact
        fields[:isolated] = true unless @access.owner?(update.user_id)
        answer = @bridge.submit(side_id, text: text, speaker: speaker_for(update),
          idempotency_key: update_key(update, "side-input"), model: pending["model"],
          workspace_public_id: workspace_id, **fields)
        accepted_request(key, answer)
        reply(update, "Your side question is accepted. The main conversation continues separately.\nTask: #{answer.fetch("input").fetch("public_id")}", request_id: key)
      end
    end
  end
end
