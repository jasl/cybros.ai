module Rho
  module IngressTelegram
    # A request may report elsewhere without moving its execution or conversation.
    # Every outgoing receipt freezes its destination when it is first queued.
    module DestinationWorkflow
      def destination_list(_update, argument)
        return "Use /destinations." unless argument.empty?

        rows = result_destinations.map { |key, _route| key }
        "Known result destinations (chat:topic; 0 means no topic):\n#{rows.join("\n")}\n\n" \
          "Use /deliver TASK_ID DESTINATION. Only allowed groups and the bot owner's private chat are listed."
      end

      def deliver_task(update, argument)
        task_id, destination, extra = argument.split(/\s+/, 3)
        unless task_id && Rho::Gateway::Commands::TASK_ID.match?(task_id) && destination && !extra
          return "Use /deliver TASK_ID DESTINATION with an exact key from /destinations."
        end
        target = result_destinations[destination]
        return "That destination is not available. Use /destinations to choose a known chat/topic." unless target

        task_id = task_id.downcase
        document = @state.read
        key, request = document.fetch("requests").find { |_id, row| row["input_id"] == task_id || row["variant_id"] == task_id }
        return "That task ID is not available. Use the full ID from its receipt." unless request

        route = document.fetch("routes").fetch(request.fetch("route_key"))
        workspace_id = workspace_for(route, request.fetch("conversation_id"))
        @bridge.conversation(request.fetch("conversation_id"), workspace_public_id: workspace_id)
        canonical = canonical_result_for(key, request) if request["execution_conversation_id"]
        turn = if request["execution_conversation_id"]
          @bridge.worker_result(canonical, workspace_public_id: workspace_id) if canonical
        else
          latest_completed_result(key, request)
        end
        media = turn ? @bridge.turn_media(turn, workspace_public_id: workspace_id) : []
        turn = nil if turn && turn.fetch("text", "").empty? && media.empty?
        text = "Task #{task_id}: future results will be delivered to #{destination}. " \
          "#{turn ? "The latest completed result is queued once for that destination. " : "There is no completed result to copy yet. "}" \
          "Already queued messages keep their destinations. Execution, memory, questions and approvals stay in the source chat/topic. " \
          "The bot owner can use /status, /stop or /steer with this task ID at the destination."
        @state.change do |saved|
          saved.fetch("requests").fetch(key)["result_destination"] = target.slice("chat_id", "topic_id", "group")
          if turn
            write_result_delivery(saved, route, request.fetch("execution_conversation_id", request.fetch("conversation_id")), turn, turn.fetch("text", ""),
              media, workspace_id, key, canonical_result: canonical)
          end
          saved.fetch("pending_update").merge!("control_status" => "applied", "control_result" => text)
        end
        text
      end

      private

        def result_destinations
          @state.read.fetch("routes").values.each_with_object({}) do |route, destinations|
            eligible = route.fetch("group") ? @access.allowed_chat?(route.fetch("chat_id")) : @access.owner?(route.fetch("chat_id"))
            destinations[destination_key(route)] ||= route if eligible
          end
        end

        def destination_key(route) = "#{route.fetch("chat_id")}:#{route["topic_id"] || 0}"

        def result_route(route, request)
          destination = request && request["result_destination"]
          destination ? route.merge(destination) : route
        end

        def destination_control?(update, request)
          destination = request["result_destination"]
          command = update.command(@bot.fetch("username"))
          owner?(update) && destination && destination_key(destination) == update.room_key &&
            %w[status stop steer].include?(command&.first)
        end

        def destination_reply_refusal(update, document)
          key = update.reply_id && document.fetch("messages")["#{update.room_key}:#{update.reply_id}"]
          return unless key && key.start_with?("delivery:")

          delivery = document.fetch("deliveries")[key.delete_prefix("delivery:")]
          request = delivery && document.fetch("requests")[delivery["request_id"]]
          return "This delivered result cannot continue its source conversation. Send a new message for this chat." unless request

          task_id = request["variant_id"] || request.fetch("input_id")
          "This is a delivered result. The bot owner can use /status #{task_id}, /stop #{task_id}, or " \
            "/steer #{task_id} TEXT at its current destination. Questions and approvals stay in the source chat/topic. " \
            "Send a new message for a separate request here."
        end

        def latest_completed_result(key, request)
          id, workspace_id = request.fetch("conversation_id"), request.fetch("workspace_public_id")
          page = @bridge.recent_turns(id, workspace_public_id: workspace_id)
          fresh_page = true
          loop do
            tracker = @state.read.fetch("routes").fetch(request.fetch("route_key")).fetch("conversations").fetch(id)
            break if map_requests(request.fetch("route_key"), id, tracker, fresh_page: fresh_page)

            fresh_page = false
          end
          loop do
            map_durable_turn_sources(page.fetch("turns"), conversation_id: id)
            turn = page.fetch("turns").reverse_each.find do |row|
              row.fetch("status") == "completed" && row.fetch("kind") == "direct_reply" && !row["inherited"] &&
                row.fetch("callback_sources", []).empty? &&
                request_for_turn(id, row.fetch("public_id"), variant_id: row["variant_public_id"])&.first == key
            end
            return turn if turn
            return unless page.fetch("pagination").fetch("has_older")

            page = @bridge.recent_turns(id, before_position: page.fetch("pagination").fetch("before_position"), workspace_public_id: workspace_id)
          end
        end

        def canonical_result_for(key, request)
          return request.fetch("canonical_result") if request["canonical_result"]

          id, workspace_id = request.fetch("conversation_id"), request.fetch("workspace_public_id")
          page = @bridge.recent_turns(id, workspace_public_id: workspace_id)
          loop do
            map_durable_turn_sources(page.fetch("turns"), conversation_id: id)
            result = @state.read.fetch("requests").fetch(key)["canonical_result"]
            return result if result
            return unless page.fetch("pagination").fetch("has_older")

            page = @bridge.recent_turns(id, before_position: page.fetch("pagination").fetch("before_position"), workspace_public_id: workspace_id)
          end
        end

        def queue_result_delivery(route, conversation_id, turn, text, media, workspace_id, request_id, canonical_result: nil)
          @state.change do |document|
            write_result_delivery(document, route, conversation_id, turn, text, media, workspace_id, request_id, canonical_result: canonical_result)
          end
        end

        def write_result_delivery(document, route, conversation_id, turn, text, media, workspace_id, request_id, canonical_result: nil)
          request_id = nil unless turn.fetch("callback_sources", []).empty?
          request = document.fetch("requests")[request_id]
          destination = request && request["result_destination"]
          target = result_route(route, request)
          identity = "#{conversation_id}:#{turn.fetch("public_id")}:#{turn.fetch("variant_public_id")}"
          key = destination ? "result:#{request_id}:#{identity}:#{destination_key(target)}" : "turn:#{identity}"
          if destination
            task_id = request["variant_id"] || request.fetch("input_id")
            text = "Task: #{task_id}\nSource chat/topic: #{request.fetch("room_key")}\n\n#{text}"
          end
          document.fetch("deliveries")[key] ||= target.slice("chat_id", "topic_id", "group", "route_key").merge(
            "status" => "pending", "text" => text, "conversation_id" => conversation_id,
            "turn_id" => turn.fetch("public_id"), "variant_public_id" => turn.fetch("variant_public_id"),
            "position" => turn["position"], "workspace_public_id" => workspace_id,
            "media" => media, "request_id" => request_id, "result_copy" => !!destination,
            "canonical_result" => canonical_result, "callback_sources" => turn.fetch("callback_sources", []),
            "report_id" => (turn["input_public_id"] || "turn:#{turn.fetch("public_id")}" unless turn.fetch("callback_sources", []).empty?)
          )
        end
    end
  end
end
