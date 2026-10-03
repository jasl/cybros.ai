module Rho
  module IngressTelegram
    # Nexus owns plans and clocks. These identities only recover Telegram owners
    # and result routes for independent executions and their ordinary callbacks.
    module ScheduledJobTracking
      private

        def reconcile_scheduled_jobs(route_key, conversation_id, tracker)
          complete = discover_scheduled_jobs(route_key, conversation_id, tracker)
          @state.read.fetch("job_bindings").each do |job_id, binding|
            next unless binding.fetch("conversation_id") == conversation_id && binding.fetch("route_key") == route_key

            page = @bridge.scheduled_job_executions(conversation_id, job_id, after: binding["execution_after"],
              workspace_public_id: binding.fetch("workspace_public_id"))
            ready = record_scheduled_executions(job_id, binding, page.fetch("executions"))
            if ready
              @state.change do |document|
                document.fetch("job_bindings").fetch(job_id)["execution_after"] = page.fetch("pagination")["last_cursor"]
              end
            end
            complete = false if page.dig("pagination", "next_after")
          end
          complete
        end

        def discover_scheduled_jobs(route_key, conversation_id, tracker)
          page = @bridge.scheduled_jobs(conversation_id, after: tracker["job_scan_after"],
            workspace_public_id: tracker.fetch("workspace_public_id"))
          adopt_scheduled_jobs(page.fetch("scheduled_jobs"), conversation_id: conversation_id)
          cursor = page.fetch("pagination")["next_after"]
          @state.change do |document|
            saved = document.fetch("routes").fetch(route_key).fetch("conversations").fetch(conversation_id)
            cursor ? saved["job_scan_after"] = cursor : saved.delete("job_scan_after")
          end
          cursor.nil?
        end

        def adopt_scheduled_jobs(rows, conversation_id:)
          return if rows.empty?

          @state.change do |document|
            rows.each do |row|
              id = row.fetch("public_id")
              next if document.fetch("job_bindings").key?(id)

              source = row["source_agent_loop_public_id"]
              key = source && request_key_for_loop(document, source)
              request = key && document.fetch("requests")[key]
              next unless request && request.fetch("conversation_id") == conversation_id

              document.fetch("job_bindings")[id] = request.slice("owner_id", "route_key", "room_key", "message_id",
                "conversation_id", "workspace_public_id").merge("source_request_id" => key)
            end
          end
        end

        def record_scheduled_executions(job_id, binding, rows)
          @state.change do |document|
            rows.each do |row|
              input_id = row.fetch("input_public_id")
              key = "scheduled:#{input_id}"
              request = document.fetch("requests")[key] ||= binding.slice("owner_id", "route_key", "room_key", "message_id",
                "conversation_id", "workspace_public_id").merge(
                "scheduled_job_id" => job_id, "input_id" => input_id,
                "execution_conversation_id" => row.fetch("child_conversation_public_id"))
              request["retired"] = true if row["status"] == "canceled" && !row["turn_public_id"]
              request["turn_id"] ||= row["turn_public_id"]
              request["loop_id"] ||= row["agent_loop_public_id"]
              work = document.fetch("work")[input_id] ||= {}
              work.merge!("request_id" => key, "turn_id" => request["turn_id"], "loop_id" => request["loop_id"])
            end
            link_work(document)
          end
          rows.all? { |row| row["agent_loop_public_id"] || %w[completed failed canceled].include?(row["status"]) }
        end

        def map_durable_turn_sources(turns, conversation_id:)
          map_worker_results(turns, conversation_id: conversation_id)
          return unless turns.any? { |turn| turn["sender_conversation_public_id"] || turn["sender_agent_loop_public_id"] }

          @state.change do |document|
            turns.each do |turn|
              next if turn["inherited"] || !turn.fetch("callback_sources", []).empty?

              source = turn["sender_agent_loop_public_id"]
              key = source && request_key_for_loop(document, source)
              if !key && turn["sender_conversation_public_id"]
                key = document.fetch("requests").find do |_id, row|
                  row["execution_conversation_id"] == turn.fetch("sender_conversation_public_id")
                end&.first
              end
              next unless key

              work = document.fetch("work").values.find { |row| row["turn_id"] == turn.fetch("public_id") }
              work ||= document.fetch("work")["turn:#{turn.fetch("public_id")}"] ||= {}
              work.merge!("request_id" => key, "source_loop_id" => source, "turn_id" => turn.fetch("public_id"),
                "loop_id" => turn["loop_public_id"])
            end
            link_work(document)
          end
        end

        def request_key_for_loop(document, loop_id)
          document.fetch("requests").find { |_key, row| row["loop_id"] == loop_id }&.first ||
            document.fetch("work").values.find { |row| row["loop_id"] == loop_id && row["request_id"] }&.fetch("request_id")
        end
    end
  end
end
