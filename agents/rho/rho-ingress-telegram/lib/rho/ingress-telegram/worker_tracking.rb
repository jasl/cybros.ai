module Rho
  module IngressTelegram
    # Worker identities and canonical result references belong to the existing
    # request receipts. Their parent follower remains the only history follower.
    module WorkerTracking
      private

        def reconcile_worker_requests(conversation_id, tracker, run)
          run.to_h.fetch("children", []).each do |child|
            next unless child.fetch("busy")

            id = child.fetch("public_id")
            turn = read_worker { @bridge.worker_request(id, workspace_public_id: tracker.fetch("workspace_public_id")) }
            next unless turn && turn["input_public_id"] && turn["sender_conversation_public_id"] == conversation_id

            @state.change do |document|
              source = request_key_for_loop(document, turn["sender_run_public_id"])
              owner = source && document.fetch("requests")[source]
              owner ||= report_owner(document, conversation_id, source_loop_id: turn["sender_run_public_id"])
              # History shows the active variant, which may be a regeneration.
              # Its loop cannot identify the original input's execution.
              register_worker(document, owner, id, turn.fetch("input_public_id"), turn.fetch("public_id"), nil, source_request_id: source)
            end
          end
        end

        def map_worker_results(turns, conversation_id:)
          turns.each do |turn|
            next if turn["inherited"]

            sources = turn.fetch("callback_sources", [])
            next if sources.empty?

            sources.each { |source| record_worker_result(source, conversation_id: conversation_id) }
            record_parent_report(turn, conversation_id)
          end
        end

        def record_parent_report(turn, conversation_id)
          sources = turn.fetch("callback_sources")
          speakers = sources.map { |source| source.fetch("result")["requester_speaker_public_id"] }.uniq
          actor = speakers.first if speakers.one?
          document = @state.read
          owner = report_owner(document, conversation_id, requester_actor_id: actor)
          key = turn["input_public_id"] || "turn:#{turn.fetch("public_id")}"
          held = document.fetch("work")[key]
          fields = (owner || {}).merge("parent_report" => true, "input_id" => turn["input_public_id"],
            "turn_id" => turn.fetch("public_id"), "run_id" => held && held["run_id"], "requester_speaker_public_id" => actor)
          if !held || fields.any? { |name, value| held[name] != value } || held["request_id"] || held["source_loop_id"]
            @state.change do |document|
              # Event replay may have tentatively linked this callback to its
              # sender before durable history supplied its full provenance.
              document.fetch("work").each_value do |work|
                next unless work["turn_id"] == turn.fetch("public_id")

                work.delete("request_id")
                work.delete("source_loop_id")
                work["parent_report"] = true
              end
              (document.fetch("work")[key] ||= {}).merge!(fields)
            end
          end
        end

        def record_worker_result(source, conversation_id:)
          result = source.fetch("result")
          document = @state.read
          existing = document.fetch("requests").find { |_key, row| row["input_id"] == result.fetch("input_public_id") }
          return if existing&.last&.fetch("canonical_result", nil)

          source_key = request_key_for_loop(document, source["sender_run_public_id"])
          owner = source_key && document.fetch("requests")[source_key]
          owner ||= report_owner(document, conversation_id, requester_actor_id: result["requester_speaker_public_id"])
          return unless existing || owner

          workspace_id = (existing&.last || owner).fetch("workspace_public_id")
          captured = read_worker do
            turn = @bridge.worker_result(result, workspace_public_id: workspace_id)
            [turn, turn ? @bridge.turn_media(turn, workspace_public_id: workspace_id) : []]
          end
          turn, media = captured
          key = existing&.first
          @state.change do |state|
            key ||= register_worker(state, owner, result.fetch("conversation_public_id"),
              result.fetch("input_public_id"), result.fetch("turn_public_id"), turn && turn["run_public_id"], source_request_id: source_key)
            request = state.fetch("requests").fetch(key)
            request["canonical_result"] ||= result
            request["run_id"] ||= turn["run_public_id"] if turn
            if turn && request["result_destination"] && (!turn.fetch("text", "").empty? || !media.empty?)
              route = state.fetch("routes").fetch(request.fetch("route_key"))
              write_result_delivery(state, route, result.fetch("conversation_public_id"), turn, turn.fetch("text", ""),
                media, workspace_id, key, canonical_result: result)
            end
          end
        end

        def register_worker(document, source, conversation_id, input_id, turn_id, run_id, source_request_id: nil)
          existing = document.fetch("requests").find { |_key, row| row["input_id"] == input_id }
          key = existing&.first || "worker:#{input_id}"
          unless existing
            return unless source

            document.fetch("requests")[key] = source.slice("owner_id", "route_key", "room_key", "message_id",
              "conversation_id", "workspace_public_id").merge("input_id" => input_id,
                "execution_conversation_id" => conversation_id, "source_request_id" => source_request_id)
          end
          request = document.fetch("requests").fetch(key)
          request["turn_id"] ||= turn_id
          request["run_id"] ||= run_id
          work = document.fetch("work")[input_id] ||= {}
          work.merge!("request_id" => key, "turn_id" => request["turn_id"], "run_id" => request["run_id"])
          key
        end

        def report_owner(document, conversation_id, requester_actor_id: nil, source_loop_id: nil)
          if source_loop_id
            report = document.fetch("work").values.find { |row| row["parent_report"] && row["run_id"] == source_loop_id }
            requester_actor_id = report && report["requester_speaker_public_id"]
          end
          return unless requester_actor_id

          owner_id = document.fetch("speakers").key(requester_actor_id)
          route = document.fetch("routes").find do |_key, row|
            owner_id && row["owner_id"] == owner_id && row.fetch("conversations").key?(conversation_id)
          end
          if route
            key, row = route
            { "owner_id" => owner_id, "route_key" => key, "room_key" => destination_key(row),
              "conversation_id" => conversation_id, "workspace_public_id" => row.fetch("conversations").fetch(conversation_id).fetch("workspace_public_id") }
          end
        end

        def read_worker
          yield
        rescue Rho::Core::Refused => error
          raise unless [403, 404, 410].include?(error.status)

          nil
        end

        def current_worker_delivery?(entry)
          current = false
          safely("worker result source") do
            result = read_worker do
              @bridge.worker_result(entry.fetch("canonical_result"), workspace_public_id: entry.fetch("workspace_public_id"))
            end
            current = result && result.fetch("status") == "completed"
            unless current
              @state.change do |document|
                document.fetch("deliveries").delete_if do |_key, row|
                  row["canonical_result"] == entry.fetch("canonical_result") && %w[pending preparing].include?(row.fetch("status"))
                end
              end
            end
          end
          current
        end
    end
  end
end
