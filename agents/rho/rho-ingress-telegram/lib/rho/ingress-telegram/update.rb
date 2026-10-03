module Rho
  module IngressTelegram
    # Telegram supplies UTF-16 offsets, not Ruby byte or codepoint positions.
    class Update
      attr_reader :id, :message, :user, :callback, :stopped

      def initialize(document, route_key = nil)
        @route_key = route_key
        @id = Integer(document.fetch("update_id"))
        @callback = document["callback_query"]
        @stopped = document["stopped_message_generation"]
        @message = @stopped || (@callback ? @callback.fetch("message", {}) : document.fetch("message", {}))
        @user = @callback ? @callback.fetch("from", {}) : @message.fetch("from", {})
      end

      def supported?
        return @message.dig("chat", "type") == "private" if @stopped

        !@message.empty? && !@user.empty? && @user["is_bot"] != true && @message.key?("chat")
      end
      def chat_id = @message.fetch("chat").fetch("id").to_s
      def user_id = @stopped ? chat_id : @user.fetch("id").to_s
      # Ordinary group replies also have a thread ID; only topic messages split routes.
      def topic_id = (@message["message_thread_id"] if @message["is_topic_message"] == true)
      def group? = @message.fetch("chat").fetch("type") != "private"
      def room_key = "#{chat_id}:#{topic_id || 0}"
      def route_key = @route_key || (group? ? "#{room_key}:#{user_id}" : room_key)
      def text = @message["text"] || @message["caption"] || ""
      def reply_id = @message.dig("reply_to_message", "message_id")
      # Callback/draft-stop updates have no event timestamp. Their exact still-pending
      # owner is checked separately; the attached message date is not the click time.
      def stale?(now, seconds) = !@callback && !@stopped && now - Integer(@message.fetch("date")) > seconds
      def route = { "chat_id" => chat_id, "topic_id" => topic_id, "group" => group? }

      def media
        if (photo = @message["photo"]&.last)
          photo.merge("kind" => "image", "filename" => "photo.jpg", "content_type" => "image/jpeg")
        elsif (voice = @message["voice"])
          voice.merge("kind" => "voice", "filename" => "voice.ogg", "content_type" => voice.fetch("mime_type", "audio/ogg"))
        elsif (document = @message["document"])
          content_type = document.fetch("mime_type", "application/octet-stream")
          kind = content_type.start_with?("image/") ? "image" : "file"
          document.merge("kind" => kind, "filename" => document.fetch("file_name", "attachment"), "content_type" => content_type)
        end
      end

      def unsupported_media?
        !media && %w[audio document video video_note animation sticker].any? { |key| @message.key?(key) }
      end

      def command(bot_name)
        match = text.match(%r{\A/([a-zA-Z0-9_]+)(?:@([a-zA-Z0-9_]+))?(?:\s+(.*))?\z}m)
        return ["unknown", ""] if !match && text.start_with?("/")
        return nil unless match
        return ["addressed_elsewhere", ""] if match[2] && !match[2].casecmp?(bot_name)

        [match[1].downcase, match[3].to_s.strip]
      end

      def triggers?(bot)
        return true unless group?
        return true if @message.dig("reply_to_message", "from", "id").to_s == bot.fetch("id").to_s

        @message.fetch(@message.key?("text") ? "entities" : "caption_entities", []).any? do |entity|
          case entity.fetch("type")
          when "mention"
            segment(entity).casecmp?("@#{bot.fetch("username")}")
          when "text_mention"
            entity.dig("user", "id").to_s == bot.fetch("id").to_s
          else
            false
          end
        end
      end

      private

        def segment(entity)
          text.encode(Encoding::UTF_16LE).byteslice(entity.fetch("offset") * 2, entity.fetch("length") * 2)
            .force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
        end
    end
  end
end
