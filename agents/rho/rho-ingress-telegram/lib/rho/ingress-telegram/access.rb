module Rho
  module IngressTelegram
    # The configured owner administers future ingress through the daemon's state.
    # A list change and its consumed-command result share one durable write.
    class Access
      USAGE = "Use /access users|chats list, /access users|chats add|remove ID, or /ignore list|add|remove ID.".freeze
      LABELS = { "allowed_users" => "Allowed users", "allowed_chats" => "Allowed groups", "ignored_users" => "Ignored users" }.freeze

      def initialize(settings:, state:)
        @settings, @state = settings, state
      end

      def owner?(user_id) = @settings.owner?(user_id)

      def ignored?(user_id)
        !owner?(user_id) && @state.read.fetch("access", {}).fetch("ignored_users", []).include?(user_id.to_s)
      end

      def allowed?(user_id)
        id = user_id.to_s
        return true if owner?(id)

        access = @state.read.fetch("access", {})
        !access.fetch("ignored_users", []).include?(id) && access.fetch("allowed_users", []).include?(id)
      end

      def allowed_chat?(chat_id) = @state.read.fetch("access", {}).fetch("allowed_chats", []).include?(chat_id.to_s)

      def document = @state.read.fetch("access")

      def change(list:, action:, id:)
        list, action = list.to_s, action.to_s
        unless LABELS.key?(list) && %w[add remove].include?(action)
          raise Rho::ConfigurationError, USAGE
        end
        id = parse_id(id.to_s, group: list == "allowed_chats")
        unless id
          raise Rho::ConfigurationError, "Use a #{list == "allowed_chats" ? "negative group" : "positive user"} numeric Telegram ID."
        end
        if owner?(id)
          raise Rho::ConfigurationError, "The bot owner is always allowed and cannot be removed or ignored."
        end

        result = "#{LABELS.fetch(list)}: #{action == "add" ? "added" : "removed"} #{id}."
        @state.change do |document|
          ids = document.fetch("access")[list] ||= []
          if action == "add"
            ids << id unless ids.include?(id)
          else
            ids.delete(id)
          end
          discard_revoked_source(document, list, action, id)
          yield(document, result) if block_given?
        end
        result
      end

      def command(update, name, argument)
        return "Only the bot owner can manage access." unless owner?(update.user_id)
        return "Manage access in a private chat with this bot." if update.group?

        words = argument.to_s.split
        case name
        when "access"
          key = { "users" => "allowed_users", "chats" => "allowed_chats" }[words.shift]
        when "ignore"
          key = "ignored_users"
        else
          return USAGE
        end
        action = words.shift
        return USAGE unless key
        return list(key) if action == "list" && words.empty?
        return USAGE unless %w[add remove].include?(action) && words.length == 1

        change(list: key, action: action, id: words.first) do |document, result|
          pending = document.fetch("pending_update")
          raise Rho::Error, "Telegram access command does not match the staged update." unless pending.fetch("update").fetch("update_id") == update.id

          pending.merge!("control_status" => "applied", "control_result" => result)
        end
      rescue Rho::ConfigurationError => error
        error.message
      end

      private

        def list(key)
          ids = @state.read.fetch("access", {}).fetch(key, [])
          result = "#{LABELS.fetch(key)}: #{ids.empty? ? "none" : ids.join(", ")}."
          key == "allowed_users" ? "Bot owner: #{@settings.owner_id}.\n#{result}" : result
        end

        def parse_id(value, group:)
          id = Integer(value, 10)
          id.to_s if group ? id.negative? : id.positive?
        rescue ArgumentError
          nil
        end

        def discard_revoked_source(document, list, action, id)
          revoked = (action == "remove" && %w[allowed_users allowed_chats].include?(list)) ||
            (list == "ignored_users" && action == "add")
          return unless revoked

          document.fetch("rooms").each do |room_key, room|
            participation = room["participation"]
            source = participation && participation["source"]
            next unless source
            next unless list == "allowed_chats" ? room_key.split(":", 2).first == id : source.fetch("user_id") == id

            # The old candidate remains until normal reconciliation cancels it
            # or records a completed send. Re-allowing cannot revive its source.
            participation.delete("source")
          end
        end
    end
  end
end
