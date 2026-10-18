module Rho
  module IngressTelegram
    # Destination state supplies admission and transport only. The originating
    # Bot keeps the task, frozen destination and all delivery receipts.
    module DeliveryRouting
      def external_bot? = named_bot? && @audience == "external"

      def result_destination(owner_id:, source_route:)
        route = @state.read.fetch("routes").values.find do |candidate|
          candidate.fetch("chat_id") == source_route.fetch("chat_id") &&
            candidate["topic_id"] == source_route["topic_id"] && candidate.fetch("group") == source_route.fetch("group") &&
            permitted_route?(candidate) && @access.allowed?(owner_id)
        end
        raise Delivery::Unavailable, Locales::ENGLISH.fetch("destination_unavailable") unless route && platform_bot && !@closed

        route.slice("chat_id", "topic_id", "group", "connection_public_id").merge("destination_agent_public_id" => @agent_public_id,
          "destination_owner_id" => owner_id)
      end

      def delivery_sender(entry)
        result_destination(owner_id: entry.fetch("destination_owner_id"), source_route: entry)
        @delivery
      end

      private

        def refresh_audience
          @audience = @bridge.bot_audience if named_bot?
        end

        def permitted_route?(route)
          if named_bot? && !external_bot?
            !route.fetch("group") && @settings.owner?(route.fetch("chat_id"))
          else
            # Accepted work retains its original recipient after a user is
            # removed from future admission. Group and destination availability
            # remain checked at delivery; no result is redirected to current.
            !route.fetch("group") || @access.allowed_chat?(route.fetch("chat_id"))
          end
        end

        def delivery_permitted?(entry)
          if entry["destination_agent_public_id"]
            request = @state.read.fetch("requests").fetch(entry.fetch("request_id"))
            route = @state.read.fetch("routes").fetch(request.fetch("route_key"))
            permitted_route?(route)
          else
            permitted_route?(entry)
          end
        end

        def bind_worker_destination(key, answerer)
          return unless @coordinator && answerer && answerer != @agent_public_id

          request = @state.read.fetch("requests").fetch(key)
          return if request.key?("answering_user_public_id")

          route = @state.read.fetch("routes").fetch(request.fetch("route_key"))
          destination = @coordinator.result_destination(agent_public_id: answerer,
            owner_id: request.fetch("owner_id"), source_route: route, source_agent_public_id: @agent_public_id)
          @state.change do |document|
            row = document.fetch("requests").fetch(key)
            row["answering_user_public_id"] = answerer
            row["result_destination"] = destination if destination
          end
        rescue Delivery::Unavailable => error
          @state.change do |document|
            row = document.fetch("requests").fetch(key)
            row.merge!("answering_user_public_id" => answerer, "delivery_error" => "destination_unavailable")
            document.fetch("deliveries")["destination-unavailable:#{key}"] ||= route.slice("chat_id", "topic_id", "group", "connection_public_id").merge(
              "status" => "pending", "plain" => true, "text" => error.message)
          end
        end
    end
  end
end
