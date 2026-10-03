module Rho
  module IngressTelegram
    # These are channel admission receipts, not agent executions. Holding a
    # voice here lets the poller keep handling Stop and questions while Nexus
    # performs its OneShot, without allowing later text to overtake that voice.
    module MediaWorkflow
      DOWNLOAD_LIMIT = 20 * 1024 * 1024
      PENDING_LIMIT = 20

      def discard_media(route_key, request_id: nil)
        removed = []
        @state.change do |document|
          document.fetch("pending_media").delete_if do |_key, row|
            matches = row.fetch("route_key") == route_key && (!request_id || row["request_id"] == request_id)
            removed << row if matches
            if matches && (request = document.fetch("requests")[row["request_id"]]) && !request["input_id"]
              request["retired"] = true
            end
            matches
          end
          document.fetch("deliveries").delete_if do |_key, row|
            matches = row["voice"] && %w[pending preparing].include?(row.fetch("status")) &&
              row["route_key"] == route_key && (!request_id || row["request_id"] == request_id)
            removed << row if matches
            matches
          end
        end
        cancel_media_receipts(removed)
      end

      private

        def cancel_media_receipts(rows)
          rows.each do |row|
            next unless row["one_shot_id"]

            safely("cancel media") { @bridge.cancel_media(id: row.fetch("one_shot_id"), workspace_public_id: row.fetch("workspace_public_id")) }
          end
        end

        def discard_source_media(conversation_id)
          removed = []
          @state.change do |document|
            document.fetch("pending_media").delete_if do |_key, row|
              matches = row.fetch("conversation_id") == conversation_id
              removed << row if matches
              matches
            end
            document.fetch("deliveries").each_value do |row|
              removed << row if row["conversation_id"] == conversation_id && row["voice"] && %w[preparing pending].include?(row.fetch("status"))
            end
          end
          cancel_media_receipts(removed)
        end

        def media_waiting?(route_key)
          @state.read.fetch("pending_media").values.any? { |row| row.fetch("route_key") == route_key }
        end

        def stage_media_input(update, conversation_id, speaker, triggered)
          key = update.id.to_s
          request_id = prepare_request(update, conversation_id)
          context = observation_context(update)
          pending = @state.read.fetch("pending_update")
          @state.change do |document|
            rows = document.fetch("pending_media")
            unless rows.key?(key)
              count = rows.values.count { |row| row.fetch("route_key") == update.route_key }
              raise Rho::Error, "Too many messages are waiting for media processing. Please try again later." if count >= PENDING_LIMIT

              observed_voice = !triggered && update.media&.fetch("kind") == "voice"
              rows[key] = update.route.merge("update_id" => update.id, "route_key" => update.route_key,
                "conversation_id" => conversation_id, "workspace_public_id" => workspace_for(room(update), conversation_id),
                "speaker" => speaker, "user_id" => update.user_id, "text" => observed_voice ? [update.text, "[Voice message]"].join("\n") : update.text,
                "model" => pending["model"], "observe" => !triggered, "media" => observed_voice ? nil : update.media,
                "input_key" => update_key(update, "input"), "request_id" => request_id, "observation_context" => context)
            end
          end
          reply(update, update.media&.fetch("kind") == "voice" ? "Transcribing your voice message." : "Your message is waiting for media processing.", request_id: request_id) if triggered
        end

        def reconcile_media
          heads = @state.read.fetch("pending_media").group_by { |_key, row| row.fetch("route_key") }
          heads.each_value do |entries|
            key, row = entries.min_by { |_id, item| item.fetch("update_id") }
            safely("media admission") { advance_media(key, row) }
          end
        end

        def advance_media(key, row)
          unless permitted_route?(row) && @access.allowed?(row.fetch("user_id"))
            @state.change do |document|
              document.fetch("pending_media").delete(key)
              request = document.fetch("requests")[row["request_id"]]
              request["retired"] = true if request && !request["input_id"]
            end
            cancel_media_receipts([row])
            return
          end
          conversation = @bridge.conversation(row.fetch("conversation_id"), workspace_public_id: row.fetch("workspace_public_id"))
          if conversation["archived_at"]
            media_notice(key, row, "This conversation is archived. Restore it before continuing, or use /new to start another conversation.")
            discard_media(row.fetch("route_key"))
            return
          end
          return unless @state.read.fetch("pending_media").key?(key)

          media = row["media"]
          if media && !row["upload_public_id"]
            upload = upload_media(row)
            return unless update_media_receipt(key, "upload_public_id" => upload)

            row = row.merge("upload_public_id" => upload)
          end
          if media && media.fetch("kind") == "voice"
            row = transcribe_media(key, row)
            return unless row
          end
          return unless @state.read.fetch("pending_media").key?(key)

          fields = { text: row.fetch("text"), speaker: row.fetch("speaker"), idempotency_key: row.fetch("input_key"),
            observe: row.fetch("observe"), model: row["model"], workspace_public_id: row.fetch("workspace_public_id") }
          tracker = @state.read.fetch("routes").fetch(row.fetch("route_key")).fetch("conversations").fetch(row.fetch("conversation_id"))
          fields[:side] = true if tracker["side_parent"]
          fields[:isolated] = true unless @access.owner?(row.fetch("user_id"))
          unless row.fetch("observe")
            names = input_tool_names(user_id: row.fetch("user_id"), group: row.fetch("group"),
              route_key: row.fetch("route_key"), conversation_id: row.fetch("conversation_id"))
            fields[:tool_names] = names unless names.nil?
          end
          fields[:upload_public_ids] = [row.fetch("upload_public_id")] if media && %w[image file].include?(media.fetch("kind"))
          fields[:inline] = [{ "role" => "user", "position" => "lead", "text" => row.fetch("observation_context") }] if row["observation_context"]
          answer = @bridge.submit(row.fetch("conversation_id"), **fields)
          accepted_request(row.fetch("request_id"), answer)
          remember_voice_input(row, answer) if media && media.fetch("kind") == "voice"
          @state.change { |document| document.fetch("pending_media").delete(key) }
        rescue Rho::Core::Refused => error
          raise if error.status >= 500 || error.status == 429

          media_notice(key, row, "Request not accepted: #{Render.preview(error.message, limit: 600)}")
          discard_media(row.fetch("route_key"))
        rescue CybrosAgent::Api::InvalidRequest, CybrosAgent::Api::Conflict, CybrosAgent::Api::Forbidden, CybrosAgent::Api::NotFound => error
          media_notice(key, row, "Media request not accepted: #{error.code || "unavailable"}.")
          discard_media(row.fetch("route_key"))
        rescue Rho::ConnectionError
          raise
        rescue Client::Refused => error
          raise if error.retry_after || error.code >= 500

          media_notice(key, row, "Telegram could not provide that media. Please resend it.")
          discard_media(row.fetch("route_key"))
        rescue Rho::Error => error
          media_notice(key, row, "Media request not accepted: #{Render.preview(error.message, limit: 600)}")
          discard_media(row.fetch("route_key"))
        end

        def upload_media(row)
          media = row.fetch("media")
          if media["file_size"] && Integer(media.fetch("file_size")) > DOWNLOAD_LIMIT
            raise Rho::Error, "Telegram media downloads are limited to 20 MB. Please send a smaller file."
          end
          file = @client.call("getFile", { file_id: media.fetch("file_id") })
          bytes = @client.download(file.fetch("file_path"), max_bytes: DOWNLOAD_LIMIT)
          @bridge.stage_media(bytes: bytes, filename: media.fetch("filename"), content_type: media.fetch("content_type"),
            idempotency_key: "#{row.fetch("input_key")}:upload", workspace_public_id: row.fetch("workspace_public_id"))
        end

        def transcribe_media(key, row)
          return row if row["transcribed"]

          result = if row["one_shot_id"]
            @bridge.transcription(id: row.fetch("one_shot_id"), workspace_public_id: row.fetch("workspace_public_id"))
          else
            @bridge.transcribe(upload_public_id: row.fetch("upload_public_id"), model: @settings.transcription_model,
              idempotency_key: "#{row.fetch("input_key")}:transcription", workspace_public_id: row.fetch("workspace_public_id"))
          end
          unless update_media_receipt(key, "one_shot_id" => result.fetch("id"))
            @bridge.cancel_media(id: result.fetch("id"), workspace_public_id: row.fetch("workspace_public_id"))
            return
          end
          case result.fetch("status")
          when "completed"
            transcript = result.fetch("text", "").strip
            raise Rho::Error, "No speech was recognized. Please resend the voice message or type it." if transcript.empty?

            text = [row.fetch("text"), transcript].reject(&:empty?).join("\n\n")
            update_media_receipt(key, "text" => text, "transcribed" => true)
            row.merge("text" => text)
          when "failed", "canceled"
            raise Rho::Error, "Voice transcription did not complete. Please resend the voice message or type it."
          else
            nil
          end
        end

        def update_media_receipt(key, fields)
          present = false
          @state.change do |document|
            if (entry = document.fetch("pending_media")[key])
              entry.merge!(fields)
              present = true
            end
          end
          present
        end

        def media_notice(key, row, text)
          @state.enqueue("media-notice:#{key}", route: row, text: text, plain: true)
        end

        def remember_voice_input(row, answer)
          input_id = answer.dig("input", "public_id")
          return unless input_id

          @state.change do |document|
            tracker = document.fetch("routes").fetch(row.fetch("route_key")).fetch("conversations")[row.fetch("conversation_id")]
            if tracker && document.fetch("routes").fetch(row.fetch("route_key")).fetch("voice", "off") == "voice_only"
              tracker["voice_inputs"] ||= []
              tracker.fetch("voice_inputs") << input_id unless tracker.fetch("voice_inputs").include?(input_id)
            end
          end
        end
    end
  end
end
