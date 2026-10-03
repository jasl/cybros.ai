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

      def command(update, name, argument, &on_change)
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

        id = parse_id(words.first, group: key == "allowed_chats")
        return "Use a #{key == "allowed_chats" ? "negative group" : "positive user"} numeric Telegram ID." unless id
        if owner?(id)
          return "The bot owner is always allowed and cannot be removed or ignored."
        end

        change(update, key, action, id, &on_change)
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

        def change(update, key, action, id)
          result = "#{LABELS.fetch(key)}: #{action == "add" ? "added" : "removed"} #{id}."
          @state.change do |document|
            pending = document.fetch("pending_update")
            raise Rho::Error, "Telegram access command does not match the staged update." unless pending.fetch("update").fetch("update_id") == update.id

            access = document["access"] ||= {}
            ids = access[key] ||= []
            if action == "add"
              ids << id unless ids.include?(id)
            else
              ids.delete(id)
            end
            yield(document, key, action, id) if block_given?
            pending.merge!("control_status" => "applied", "control_result" => result)
          end
          result
        end
    end
  end
end
