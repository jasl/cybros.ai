module Rho
  module IngressTelegram
    # Changing a candidate does not advance the turn position. The explicit
    # control watches that position separately from the forward history cursor.
    module CandidateWorkflow
      private

        def reconcile_candidates(route_key, route, conversation_id, cursor)
          cursor.fetch("candidate_watches", {}).each do |watch_key, watch|
            turn_id = watch.fetch("turn_id", watch_key)
            current = read_source(conversation_id) do
              @bridge.turn_source(conversation_id, position: watch.fetch("position"), workspace_public_id: cursor.fetch("workspace_public_id"))
            end
            unless current && current.fetch("public_id") == turn_id
              clear_candidate_watch(route_key, conversation_id, watch_key, watch)
              next
            end

            deck = read_source(conversation_id) do
              @bridge.variants(conversation_id, turn_id, workspace_public_id: cursor.fetch("workspace_public_id"))
            end
            next unless deck
            candidate = if watch["variant_id"]
              deck.find { |row| row.fetch("public_id") == watch.fetch("variant_id") }
            else
              deck.find { |row| !watch.fetch("known_variants").include?(row.fetch("public_id")) }
            end
            if candidate && candidate["agent_loop_public_id"]
              register_candidate_request(route_key, conversation_id, cursor.fetch("workspace_public_id"), turn_id, candidate, watch)
            end
            if candidate && current.fetch("variant_public_id") == candidate.fetch("public_id") &&
                current.fetch("variant_public_id") != watch["previous_variant"] && !%w[pending running].include?(current.fetch("status"))
              collect_turns(route_key, route, conversation_id, cursor, [current])
              clear_candidate_watch(route_key, conversation_id, watch_key, watch)
            elsif candidate && %w[failed canceled timed_out].include?(candidate.fetch("status"))
              @state.enqueue("candidate:#{conversation_id}:#{candidate.fetch("public_id")}", route: route,
                text: "The new candidate #{candidate.fetch("status")}. The previous answer remains selected. Use /variants #{watch.fetch("position")}.",
                conversation_id: conversation_id, plain: true)
              clear_candidate_watch(route_key, conversation_id, watch_key, watch)
            end
          end
          @state.read.fetch("routes").dig(route_key, "conversations", conversation_id)
        end

        def register_candidate_request(route_key, conversation_id, workspace_id, turn_id, candidate, watch)
          variant_id = candidate.fetch("public_id")
          key = "telegram:#{@bot.fetch("id")}:candidate:#{variant_id}"
          @state.change do |document|
            document.fetch("requests")[key] ||= {
              "owner_id" => watch.fetch("owner_id"), "route_key" => route_key, "room_key" => watch.fetch("room_key"),
              "message_id" => watch["message_id"], "conversation_id" => conversation_id,
              "workspace_public_id" => workspace_id, "turn_id" => turn_id,
              "variant_id" => variant_id, "loop_id" => candidate.fetch("agent_loop_public_id"),
            }
            if watch["message_id"]
              document.fetch("messages")["#{watch.fetch("room_key")}:#{watch.fetch("message_id")}"] = key
            end
            link_work(document)
          end
          key
        end

        def clear_candidate_watch(route_key, conversation_id, watch_key, watch)
          @state.change do |document|
            watches = document.fetch("routes").dig(route_key, "conversations", conversation_id, "candidate_watches")
            watches.delete(watch_key) if watches && watches[watch_key] == watch
          end
        end
    end
  end
end
