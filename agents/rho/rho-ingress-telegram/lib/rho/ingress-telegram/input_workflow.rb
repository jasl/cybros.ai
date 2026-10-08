module Rho
  module IngressTelegram
    # Channel admission owns the brief IM quiet window and media preparation.
    # Source receipts persist before the poll offset advances. Commands stay
    # immediate; Nexus owns execution only after the assembled input is accepted.
    module InputWorkflow
      DOWNLOAD_LIMIT = 20 * 1024 * 1024
      PENDING_LIMIT = 20

      def discard_pending_inputs(route_key, request_id: nil)
        removed = []
        @state.change do |document|
          submitting = document.fetch("pending_inputs").values.filter_map { |row| row.fetch("batch_key") if row["submission"] }
          document.fetch("pending_inputs").delete_if do |_key, row|
            matches = row.fetch("route_key") == route_key && (!request_id || row["request_id"] == request_id)
            # Once submitted, an unknown response may already own execution.
            # Route changes leave that receipt attached to its original target;
            # a preadmission Stop cannot truthfully claim it canceled the call.
            if matches && submitting.include?(row.fetch("batch_key"))
              raise Rho::Error, Locales::ENGLISH.fetch("input_admission_started") if request_id

              next false
            end
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
            next unless row["inference_request_id"]

            safely("cancel media") { @bridge.cancel_media(id: row.fetch("inference_request_id"), workspace_public_id: row.fetch("workspace_public_id")) }
          end
        end

        def discard_source_inputs(conversation_id)
          removed = []
          @state.change do |document|
            document.fetch("pending_inputs").delete_if do |_key, row|
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

        def burst_waiting?(update)
          @state.read.fetch("pending_inputs").values.any? do |row|
            row.fetch("route_key") == update.route_key && row.fetch("user_id") == update.user_id &&
              !row["media"] && row.fetch("ready_at") > @clock.call
          end
        end

        def stage_input(update, conversation_id, speaker, triggered)
          key = update.id.to_s
          request_id = prepare_request(update, conversation_id)
          context = observation_context(update)
          pending = @state.read.fetch("pending_update")
          @state.change do |document|
            rows = document.fetch("pending_inputs")
            unless rows.key?(key)
              count = rows.values.count { |row| row.fetch("route_key") == update.route_key }
              raise Rho::Error, Locales::ENGLISH.fetch("input_admission_limit") if count >= PENDING_LIMIT

              observed_voice = !triggered && update.media&.fetch("kind") == "voice"
              row = update.route.merge("update_id" => update.id, "route_key" => update.route_key,
                "conversation_id" => conversation_id, "workspace_public_id" => workspace_for(room(update), conversation_id),
                "speaker" => speaker, "user_id" => update.user_id, "text" => observed_voice ? [update.text, "[Voice message]"].join("\n") : update.text,
                "model" => pending["model"], "observe" => !triggered, "media" => observed_voice ? nil : update.media,
                "input_key" => update_key(update, "input"), "request_id" => request_id, "observation_context" => context,
                "message_date" => update.message.fetch("date"), "batch_key" => key,
                "ready_at" => @clock.call + (update.media ? 0 : @settings.input_debounce_seconds))
              previous = rows.values.reverse_each.find { |item| item.fetch("route_key") == update.route_key }
              submitted = previous && rows.values.any? { |item| item.fetch("batch_key") == previous.fetch("batch_key") && item["submission"] }
              if previous && !submitted && batchable?(previous, row)
                row["batch_key"] = previous.fetch("batch_key")
                rows.each_value { |item| item["ready_at"] = row.fetch("ready_at") if item.fetch("batch_key") == row.fetch("batch_key") }
              end
              rows[key] = row
            end
          end
          if triggered && update.media
            reply(update, update.media.fetch("kind") == "voice" ? "Transcribing your voice message." : "Your message is waiting for media processing.", request_id: request_id)
          end
        end

        def batchable?(previous, row)
          !previous["media"] && !row["media"] && previous.fetch("ready_at") > @clock.call &&
            %w[conversation_id workspace_public_id speaker user_id model observe observation_context].all? { |field| previous[field] == row[field] }
        end

        def reconcile_inputs(media: true)
          heads = @state.read.fetch("pending_inputs").group_by { |_key, row| row.fetch("route_key") }
          heads.each_value do |entries|
            key, row = entries.min_by { |_id, item| item.fetch("update_id") }
            next if row["media"] && !media
            next if row.fetch("ready_at") > @clock.call

            safely("media admission") { advance_input(key, row) }
          end
        end

        def advance_input(key, row)
          if @clock.call - row.fetch("message_date") >= 24 * 60 * 60 - 1
            media_notice(key, row, Locales::ENGLISH.fetch("input_recovery_expired"))
            retire_input_batch(row.fetch("batch_key"))
            return
          end
          unless permitted_route?(row) && @access.allowed?(row.fetch("user_id"))
            retire_input_batch(row.fetch("batch_key"))
            return
          end
          conversation = @bridge.conversation(row.fetch("conversation_id"), workspace_public_id: row.fetch("workspace_public_id"))
          if conversation["archived_at"]
            media_notice(key, row, "This conversation is archived. Restore it before continuing, or use /new to start another conversation.")
            discard_pending_inputs(row.fetch("route_key"))
            return
          end
          return unless @state.read.fetch("pending_inputs").key?(key)

          media = row["media"]
          if media && !row["upload_public_id"]
            upload = upload_media(row)
            return unless update_input_receipt(key, "upload_public_id" => upload)

            row = row.merge("upload_public_id" => upload)
          end
          if media && media.fetch("kind") == "voice"
            row = transcribe_media(key, row)
            return unless row
          end
          return unless @state.read.fetch("pending_inputs").key?(key)

          fields = row["submission"] || prepare_submission(key, row)
          return unless fields

          answer = @bridge.submit(row.fetch("conversation_id"), **fields.transform_keys(&:to_sym))
          entries = @state.read.fetch("pending_inputs").select { |_id, item| item.fetch("batch_key") == row.fetch("batch_key") }
          entries.each_value { |item| accepted_request(item.fetch("request_id"), answer) }
          remember_voice_input(row, answer) if media && media.fetch("kind") == "voice"
          @state.change { |document| entries.each_key { |id| document.fetch("pending_inputs").delete(id) } }
        rescue Rho::Core::Refused => error
          raise if error.status >= 500 || error.status == 429

          media_notice(key, row, "Request not accepted: #{Render.preview(error.message, limit: 600)}")
          retire_input_batch(row.fetch("batch_key"))
        rescue CybrosAgent::Api::InvalidRequest, CybrosAgent::Api::Conflict, CybrosAgent::Api::Forbidden, CybrosAgent::Api::NotFound => error
          media_notice(key, row, Locales::ENGLISH.fetch("input_not_accepted") % { reason: error.code || "unavailable" })
          retire_input_batch(row.fetch("batch_key"))
        rescue Rho::ConnectionError
          raise
        rescue Client::Refused => error
          raise if error.retry_after || error.code >= 500

          media_notice(key, row, "Telegram could not provide that media. Please resend it.")
          retire_input_batch(row.fetch("batch_key"))
        rescue Rho::Error => error
          media_notice(key, row, Locales::ENGLISH.fetch("input_not_accepted") % { reason: Render.preview(error.message, limit: 600) })
          retire_input_batch(row.fetch("batch_key"))
        end

        def prepare_submission(key, row)
          fields = { speaker: row.fetch("speaker"), idempotency_key: row.fetch("input_key"),
            mode: "queue", observe: row.fetch("observe"), model: row["model"], workspace_public_id: row.fetch("workspace_public_id") }
          fields[:isolated] = true unless @access.owner?(row.fetch("user_id"))
          unless row.fetch("observe")
            names = input_tool_names(user_id: row.fetch("user_id"), group: row.fetch("group"),
              route_key: row.fetch("route_key"), conversation_id: row.fetch("conversation_id"))
            fields[:tool_names] = names unless names.nil?
          end
          fields[:upload_public_ids] = [row.fetch("upload_public_id")] if row["media"] && %w[image file].include?(row.fetch("media").fetch("kind"))
          fields[:inline] = [{ "role" => "user", "position" => "lead", "text" => row.fetch("observation_context") }] if row["observation_context"]
          # Tool selection may yield to a new message or Stop. Select and freeze
          # the current sources in one write after that IO, preserving both a
          # successful cancellation and any newly extended quiet deadline.
          saved = nil
          @state.change do |document|
            entry = document.fetch("pending_inputs")[key]
            next unless entry && entry.fetch("ready_at") <= @clock.call

            entries = document.fetch("pending_inputs").values.select { |item| item.fetch("batch_key") == row.fetch("batch_key") }
            entry["submission"] ||= fields.merge(text: entries.map { |item| item.fetch("text") }.join("\n\n")).transform_keys(&:to_s)
            saved = entry.fetch("submission")
          end
          saved
        end

        def retire_input_batch(batch_key)
          removed = []
          @state.change do |document|
            document.fetch("pending_inputs").delete_if do |_key, row|
              next false unless row.fetch("batch_key") == batch_key

              removed << row
              request = document.fetch("requests").fetch(row.fetch("request_id"))
              request["retired"] = true unless request["input_id"]
              true
            end
          end
          cancel_media_receipts(removed)
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

          result = if row["inference_request_id"]
            @bridge.transcription(id: row.fetch("inference_request_id"), workspace_public_id: row.fetch("workspace_public_id"))
          else
            @bridge.transcribe(upload_public_id: row.fetch("upload_public_id"), model: @settings.transcription_model,
              idempotency_key: "#{row.fetch("input_key")}:transcription", workspace_public_id: row.fetch("workspace_public_id"))
          end
          unless update_input_receipt(key, "inference_request_id" => result.fetch("id"))
            @bridge.cancel_media(id: result.fetch("id"), workspace_public_id: row.fetch("workspace_public_id"))
            return
          end
          case result.fetch("status")
          when "completed"
            transcript = result.fetch("text", "").strip
            raise Rho::Error, "No speech was recognized. Please resend the voice message or type it." if transcript.empty?

            text = [row.fetch("text"), transcript].reject(&:empty?).join("\n\n")
            update_input_receipt(key, "text" => text, "transcribed" => true)
            row.merge("text" => text)
          when "failed", "canceled"
            raise Rho::Error, "Voice transcription did not complete. Please resend the voice message or type it."
          else
            nil
          end
        end

        def update_input_receipt(key, fields)
          present = false
          @state.change do |document|
            if (entry = document.fetch("pending_inputs")[key])
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
