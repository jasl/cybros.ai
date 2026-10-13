require "digest"
require "async/semaphore"

module Rho
  module IngressTelegram
    # A persisted formal send is attempted once unless Telegram explicitly refuses it.
    # Progress is replaceable; it never serves as the receipt for a final answer.
    class Delivery
      class Unavailable < Rho::Error; end

      # Telegram shows "typing…" for about five seconds or until a message
      # arrives, so the action is re-sent on this cadence while a reply runs.
      TYPING_INTERVAL = 5

      def initialize(client:, state:, bridge: nil, limits: RateLimit.new, clock: -> { Time.now.to_f }, destination: nil,
                     transport: nil)
        @client, @state, @bridge, @limits, @clock = client, state, bridge, limits, clock
        @destination = destination
        @sending = Async::Semaphore.new(1)
        @transport = transport
        @progress = {}
        @typing = {}
      end

      def flush
        @state.read.fetch("deliveries").each do |key, entry|
          # One follower owns flush. A sending row encountered on a later pass
          # survived a lost Nexus receipt; its external outcome is unconfirmed.
          if entry.fetch("status") == "sending"
            stamp(key, "status" => "uncertain")
            next
          end
          next unless entry.fetch("status") == "pending"
          next if entry.fetch("retry_at", 0) > @clock.call

          # A source check can retire several entries from this flush's snapshot.
          entry = @state.read.fetch("deliveries")[key]
          next unless entry && entry.fetch("status") == "pending"

          send_part(key, entry) { !block_given? || yield(entry) }
        end
      end

      # Borrowing another Bot's transport does not move a receipt. Its ordinary
      # messages, previews and borrowed sends share this same budget and slot.
      def with_send(entry, progress: false)
        return @transport.call(entry).with_send(entry, progress: progress) { |client| yield(client) } if @transport

        @sending.acquire do
          next unless ready?(entry, progress: progress)

          result = yield(@client)
          @limits.sent(**budget(entry), progress: progress) if result
          result
        end
      end

      def throttle(seconds, entry: {})
        return @transport.call(entry).throttle(seconds) if @transport

        @limits.retry_after(seconds)
        @state.change do |document|
          document["retry_at"] = [document.fetch("retry_at", 0), @clock.call + seconds].max
        end
      end

      def progress(route, conversation_id, snapshot)
        run_id = snapshot["run_public_id"]
        return if run_id.to_s.empty?

        status = snapshot.fetch("status")
        live = %w[running pending queued waiting needs_attention paused].include?(status)
        key = "#{conversation_id}:#{run_id}"
        typing(route, key, live: live && status == "running")
        unless status == "superseded"
          @progress.each do |previous_key, previous|
            next unless previous_key.start_with?("#{conversation_id}:") && previous_key != key
            next unless previous["text"] && !previous["terminal"]

            # A WebUI control can replace the current loop between follower reads.
            # Retire only our old preview; this does not claim its background work stopped.
            progress(route, conversation_id, { "run_public_id" => previous.fetch("run_id"), "status" => "superseded" })
          end
        end
        # Terminal snapshots only finish a preview this process actually sent.
        return if !live && !@progress.dig(key, "text")

        held = (@progress[key] ||= { "draft_id" => Digest::SHA256.hexdigest(key)[0, 7].to_i(16) + 1, "run_id" => run_id })
        if !live && !held["message_id"]
          # A formal answer ends the temporary draft. Publishing a terminal
          # draft afterward can reintroduce a status bubble, or fall back to a
          # new ordinary message. Only an existing ordinary preview needs editing.
          held["terminal"] = true
          return
        end
        return if held["disabled"] || !ready?(route, progress: true)
        return if held["terminal"]

        text = progress_text(status, live ? snapshot["action"] : nil)
        return if held["text"] == text && @clock.call - held.fetch("at", 0) < 15

        # The draft's exact owner survives a restart; old stop events never pick a new loop.
        @state.change do |document|
          owner = document.fetch("routes").values.find { |row| row.fetch("conversations").key?(conversation_id) }
          if owner
            owner["draft"] = { "id" => held.fetch("draft_id"), "conversation_id" => conversation_id, "run_id" => run_id }
          end
        end
        method, params = progress_request(route, held, text, live)
        answer = with_send(route, progress: true) { |client| client.call(method, params) }
        return unless answer

        held["message_id"] = answer["message_id"] if method == "sendMessage"
        held["text"], held["at"], held["terminal"] = text, @clock.call, !live
      rescue Client::Refused => error
        if error.retry_after
          throttle(error.retry_after, entry: route)
        elsif !route.fetch("group") && !held["plain"]
          held["plain"] = true
        elsif error.code == 400 && error.description.include?("not modified")
          held["text"], held["at"] = text, @clock.call
        else
          held["disabled"] = true
        end
      rescue Client::Unavailable
        # Editing an existing message/draft is replaceable. Creating a new progress
        # message after an uncertain POST risks duplicates, so stop that preview.
        held["disabled"] = true if method == "sendMessage"
      end

      private

        # The chat's own "working" signal while the reply actually runs: a
        # chat action, outside the message budget, never retried. A refusal
        # other than a throttle ends it for that execution; the next
        # execution starts fresh.
        def typing(route, key, live:)
          unless live
            @typing.delete(key)
            return
          end
          held = (@typing[key] ||= {})
          return if held["disabled"] || @clock.call - held.fetch("at", 0) < TYPING_INTERVAL
          transport = @transport&.call(route)
          return if (transport ? transport.state : @state).read.fetch("retry_at", 0) > @clock.call

          held["at"] = @clock.call
          (transport ? transport.client : @client).call("sendChatAction", { chat_id: route.fetch("chat_id"), message_thread_id: route["topic_id"], action: "typing" }.compact)
        rescue Client::Refused => error
          if error.retry_after
            throttle(error.retry_after, entry: route)
          else
            held["disabled"] = true
          end
        rescue Client::Unavailable
          nil
        end

        def budget(entry) = { chat_id: entry.fetch("chat_id"), group: entry.fetch("group") }
        def ready?(entry, progress: false)
          return @transport.call(entry).ready?(entry, progress: progress) if @transport

          @state.read.fetch("retry_at", 0) <= @clock.call &&
            @limits.ready?(**budget(entry), progress: progress)
        end

        def send_part(key, entry)
          sender = entry["destination_agent_public_id"] ? @destination&.call(entry) : self
          raise Unavailable, Locales::ENGLISH.fetch("destination_unavailable") unless sender

          parts = Render.chunks(entry.fetch("text"), plain: entry.fetch("plain", false))
          index = entry.fetch("part", 0)
          params = { chat_id: entry.fetch("chat_id"), message_thread_id: entry["topic_id"] }.compact
          request = @state.read.fetch("requests")[entry["request_id"]]
          copied = entry["destination_agent_public_id"] || entry["result_copy"] ||
            (request && request.fetch("room_key") != Update.room_key(chat_id: entry.fetch("chat_id"), topic_id: entry["topic_id"], connection_public_id: entry["connection_public_id"]))
          if request && request["message_id"] && !copied
            params[:reply_parameters] = { message_id: request.fetch("message_id"), allow_sending_without_reply: true }
          end
          media = entry.fetch("media", [])
          if index < parts.length
            part = parts.fetch(index)
            params.merge!(entry["plain"] || entry["format_fallback"] ? part.plain : part.formatted)
            params[:reply_markup] = entry["reply_markup"] if entry["reply_markup"]
            result = sender.with_send(entry) do |client|
              next if block_given? && !yield

              if entry["destination_agent_public_id"] && !@destination.call(entry).equal?(sender)
                raise Unavailable, Locales::ENGLISH.fetch("destination_unavailable")
              end
              stamp(key, "status" => "sending")
              client.call("sendMessage", params)
            end
          else
            item = media.fetch(index - parts.length)
            if item.fetch("byte_size") > 50 * 1024 * 1024
              refuse_media_size(key, entry)
              return
            end
            method, field = media_method(entry, item, index)
            bytes = media_bytes(key, entry, item)
            return unless bytes

            if bytes.bytesize > 50 * 1024 * 1024
              refuse_media_size(key, entry)
              return
            end
            return if block_given? && !yield
            return unless @state.read.fetch("deliveries").dig(key, "status") == "pending"

            result = sender.with_send(entry) do |client|
              next if block_given? && !yield

              if entry["destination_agent_public_id"] && !@destination.call(entry).equal?(sender)
                raise Unavailable, Locales::ENGLISH.fetch("destination_unavailable")
              end
              stamp(key, "status" => "sending")
              client.upload(method, params, bytes: bytes, filename: item.fetch("filename"),
                content_type: item.fetch("content_type"), field: field)
            end
          end
          return unless result

          @state.change do |document|
            receipt = document.fetch("deliveries").fetch(key)
            receipt["message_ids"] ||= []
            receipt.fetch("message_ids") << result.fetch("message_id")
            if !entry["destination_agent_public_id"] &&
                (owner = entry["request_id"] || entry["participation_key"] || ("report:#{entry.fetch("report_id")}" if entry["report_id"]))
              document.fetch("messages")["#{Update.room_key(chat_id: entry.fetch("chat_id"), topic_id: entry["topic_id"], connection_public_id: entry["connection_public_id"])}:#{result.fetch("message_id")}"] = copied ? "delivery:#{key}" : owner
            end
            receipt["part"] = index + 1
            receipt["status"] = index + 1 == parts.length + media.length ? "sent" : "pending"
            receipt["sent_at"] = @clock.call if entry["participation_key"] && receipt["status"] == "sent"
            receipt.delete("text") if receipt["status"] == "sent"
            if (question = document.fetch("questions")[entry["question_id"]])
              question["message_ids"] = question.fetch("message_ids", []) | receipt.fetch("message_ids")
            end
          end
        rescue Client::Refused => error
          if error.retry_after
            sender.throttle(error.retry_after, entry: entry)
            stamp(key, "status" => "pending")
          elsif error.code == 400 && %w[sendPhoto sendVoice].include?(method)
            stamp(key, "status" => "pending", "document_parts" => entry.fetch("document_parts", []) + [index])
          elsif error.code == 400 && index < parts.length && !entry["plain"] && !entry["format_fallback"]
            # This was explicitly refused, so retrying as plain text cannot duplicate it.
            stamp(key, "status" => "pending", "format_fallback" => true)
          elsif error.code >= 500
            stamp(key, "status" => "pending", "retry_at" => @clock.call + 10)
          else
            stamp(key, "status" => "refused", "error_code" => error.code)
          end
        rescue Client::Unavailable => error
          stamp(key, "status" => (error.ambiguous ? "uncertain" : "pending"), "retry_at" => @clock.call + 10)
        rescue Unavailable => error
          @state.change do |document|
            document.fetch("deliveries").fetch(key).merge!("status" => "refused", "error_code" => "destination_unavailable", "error" => error.message)
            request = document.fetch("requests")[entry["request_id"]]
            route = request && document.fetch("routes")[request["route_key"]]
            if route
              document.fetch("deliveries")["destination-unavailable:#{key}"] ||= route.slice("chat_id", "topic_id", "group", "connection_public_id").merge(
                "status" => "pending", "plain" => true, "text" => error.message)
            end
          end
        end

        def refuse_media_size(key, entry)
          stamp(key, "status" => "refused", "error_code" => "media_too_large")
          @state.enqueue("media-limit:#{key}", route: entry,
            text: "This attachment exceeds Telegram's 50 MB limit. The text reply is still available.", plain: true)
        end

        def media_bytes(key, entry, item)
          @bridge.media_bytes(item, workspace_public_id: entry.fetch("workspace_public_id"))
        rescue Rho::Core::Refused => error
          raise unless [403, 404, 410].include?(error.status)

          refuse_missing_media(key, entry)
          nil
        rescue CybrosAgent::Api::Forbidden, CybrosAgent::Api::NotFound
          refuse_missing_media(key, entry)
          nil
        end

        def refuse_missing_media(key, entry)
          # Retention can remove capture bytes while the final turn remains readable.
          # A source change during the read may already have retired this receipt.
          return unless @state.read.fetch("deliveries").dig(key, "status") == "pending"

          stamp(key, "status" => "refused", "error_code" => "media_unavailable")
          @state.enqueue("media-unavailable:#{key}", route: entry,
            text: "This attachment is no longer available. The text reply is still available.", plain: true)
        end

        def media_method(entry, media, index)
          if entry["voice"] && %w[audio/ogg audio/mpeg audio/mp4].include?(media.fetch("content_type")) && !entry.fetch("document_parts", []).include?(index)
            ["sendVoice", "voice"]
          elsif media.fetch("content_type").start_with?("image/") && media.fetch("byte_size") <= 10 * 1024 * 1024 && !entry.fetch("document_parts", []).include?(index)
            ["sendPhoto", "photo"]
          else
            ["sendDocument", "document"]
          end
        end

        def stamp(key, attributes)
          @state.change { |document| document.fetch("deliveries").fetch(key).merge!(attributes) }
        end

        def progress_text(status, action)
          heading = case status
          when "pending", "queued" then "Your request is queued."
          when "running" then "Working on your request."
          when "waiting" then "Waiting for your response."
          when "needs_attention", "failed" then "This request needs attention."
          when "canceled", "stopped" then "Stopped."
          when "paused" then "Paused."
          when "completed" then "Completed."
          when "superseded" then "This execution is no longer current."
          else "Checking the request status."
          end
          Render.preview([heading, action && "Now: #{action}"].compact.join("\n"))
        end

        def progress_request(route, held, text, live)
          params = { chat_id: route.fetch("chat_id"), message_thread_id: route["topic_id"] }.compact
          if !route.fetch("group") && !held["plain"]
            ["sendMessageDraft", params.merge(draft_id: held.fetch("draft_id"), text: text, can_stop: live)]
          elsif held["message_id"]
            ["editMessageText", params.merge(message_id: held.fetch("message_id"), text: text)]
          else
            ["sendMessage", params.merge(text: text)]
          end
        end
    end
  end
end
