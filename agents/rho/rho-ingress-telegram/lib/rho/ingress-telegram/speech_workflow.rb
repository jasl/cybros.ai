module Rho
  module IngressTelegram
    # Speech is an optional rendering of a final reply. Its OneShot receipt
    # lives with that outgoing delivery; text is never held behind synthesis.
    module SpeechWorkflow
      private

        def cancel_task_speech(target)
          removed = []
          @state.change do |document|
            document.fetch("deliveries").delete_if do |_key, row|
              matches = row["voice"] && %w[pending preparing].include?(row.fetch("status")) &&
                row["conversation_id"] == target.fetch("conversation_id") && row["turn_id"] == target["turn_id"]
              removed << row if matches
              matches
            end
          end
          cancel_media_receipts(removed)
        end

        def map_voice_inputs(route_key, conversation_id, tracker)
          pending = tracker.fetch("voice_inputs", [])
          return if pending.empty?

          @state.change do |document|
            held = document.fetch("routes").fetch(route_key).fetch("conversations")[conversation_id]
            next unless held

            pending.each do |input_id|
              turn_id = document.fetch("work").dig(input_id, "turn_id")
              next unless turn_id

              held["voice_turns"] ||= []
              held.fetch("voice_turns") << turn_id
              held.fetch("voice_inputs").delete(input_id)
            end
          end
        end

        def queue_speech(route_key, route, conversation_id, turn, text, workspace_id)
          mode = route.fetch("voice", "off")
          tracker = @state.read.fetch("routes").fetch(route_key).fetch("conversations").fetch(conversation_id)
          from_voice = tracker.fetch("voice_turns", []).include?(turn.fetch("public_id"))
          return if text.empty? || @settings.speech_model.empty? || mode == "off" || (mode == "voice_only" && !from_voice)

          # 600 UTF-16 units fit within the shipped speech lane's 2000-byte
          # input bound even for three-byte CJK. No spoken text is truncated.
          previous = nil
          request = request_for_turn(conversation_id, turn.fetch("public_id"), variant_id: turn["variant_public_id"])
          request = nil unless turn.fetch("callback_sources", []).empty?
          target = result_route(route, request&.last)
          copied = !!request&.last&.fetch("result_destination", nil)
          Render.chunks(text, limit: 600).each_with_index do |part, index|
            key = "voice:#{conversation_id}:#{turn.fetch("public_id")}:#{turn.fetch("variant_public_id")}:#{index}"
            key += ":#{destination_key(target)}" if copied
            @state.enqueue(key, route: target, text: "",
              status: "preparing", speech_text: part.text, model: @settings.speech_model, voice: true, speech_after: previous,
              conversation_id: conversation_id, turn_id: turn.fetch("public_id"),
              variant_public_id: turn.fetch("variant_public_id"), position: turn.fetch("position"), workspace_public_id: workspace_id,
              request_id: request&.first, result_copy: copied, callback_sources: turn.fetch("callback_sources", []),
              report_id: (turn["input_public_id"] || "turn:#{turn.fetch("public_id")}" unless turn.fetch("callback_sources", []).empty?))
            previous = key
          end
        end

        def reconcile_speech
          @state.read.fetch("deliveries").each do |key, entry|
            next unless entry.fetch("status") == "preparing" && entry["voice"]
            next unless permitted_route?(entry)

            safely("speech") { advance_speech(key, entry) }
          end
        end

        def advance_speech(key, entry)
          return unless current_delivery?(entry)

          # Only one spoken part is synthesized at a time. A sent predecessor is
          # pruned; a refused or uncertain one must not be skipped audibly.
          predecessor = @state.read.fetch("deliveries")[entry["speech_after"]]
          if predecessor
            if %w[refused uncertain].include?(predecessor.fetch("status"))
              @state.change { |document| document.fetch("deliveries")[key]&.merge!("status" => "refused") }
            end
            return unless predecessor.fetch("status") == "sent"
          end

          result = if entry["one_shot_id"]
            @bridge.speech(id: entry.fetch("one_shot_id"), workspace_public_id: entry.fetch("workspace_public_id"))
          else
            @bridge.speech_start(text: entry.fetch("speech_text"), model: entry.fetch("model"),
              idempotency_key: "telegram:#{@bot.fetch("id")}:#{key}", workspace_public_id: entry.fetch("workspace_public_id"))
          end
          missing_media = result.fetch("status") == "completed" && !result["media"]
          active = false
          @state.change do |document|
            held = document.fetch("deliveries")[key]
            next unless held

            active = true
            held["one_shot_id"] = result.fetch("id")
            case result.fetch("status")
            when "completed"
              held.merge!("status" => missing_media ? "refused" : "pending", "media" => [result["media"]].compact)
              held.delete("speech_text")
            when "failed", "canceled"
              held["status"] = "refused"
            else
              nil
            end
          end
          @bridge.cancel_media(id: result.fetch("id"), workspace_public_id: entry.fetch("workspace_public_id")) unless active
          speech_notice(key, entry) if missing_media || %w[failed canceled].include?(result.fetch("status"))
        rescue Rho::ConnectionError
          raise
        rescue Rho::Core::Refused => error
          raise if error.status >= 500 || error.status == 429

          @state.change { |document| document.fetch("deliveries")[key]&.merge!("status" => "refused") }
          speech_notice(key, entry)
        rescue Rho::Error, CybrosAgent::Api::InvalidRequest, CybrosAgent::Api::Conflict, CybrosAgent::Api::Forbidden
          @state.change { |document| document.fetch("deliveries")[key]&.merge!("status" => "refused") }
          speech_notice(key, entry)
        end

        def speech_notice(key, entry)
          @state.enqueue("speech-notice:#{key}", route: entry, text: "The spoken reply could not be generated. The text reply is still available.", plain: true)
        end
    end
  end
end
