require "rho/store_document"

module Rho
  module IngressTelegram
    # Channel routing, Telegram consumption and external delivery receipts.
    # Nexus remains the authority for accepted input and completed response bodies.
    class State
      def initialize(store:, migration: nil)
        @store, @migration = store, migration
      end

      def read
        @migration&.claim
        document = @store.read
        @migration&.complete if document
        defaults(document || {})
      end

      def defaults(document)
        document["offset"] ||= nil
        %w[routes speakers deliveries questions].each { |name| document[name] ||= {} }
        document.fetch("routes").each_value do |route|
          route["owner_id"] ||= route.fetch("chat_id") if route["group"] == false
        end
        document["pending_media"] ||= {}
        document["rooms"] ||= {}
        document["requests"] ||= {}
        document["work"] ||= {}
        document["messages"] ||= {}
        document["job_bindings"] ||= {}
        document["access"] ||= { "allowed_users" => [], "allowed_chats" => [], "ignored_users" => [] }
        document
      end

      def binding(conversation_id)
        route = read.fetch("routes").values.find do |row|
          row["current"] == conversation_id ||
            (row["current"] && row.fetch("conversations").dig(conversation_id, "side_parent") == row["current"])
        end
        if route
          label = "Telegram · Chat #{route.fetch("chat_id")}"
          label += " · Topic #{route.fetch("topic_id")}" if route["topic_id"]
          label += " · User #{route.fetch("owner_id")}" if route["group"] && route["owner_id"]
          { "channel" => "telegram", "label" => label,
            "chat_id" => route.fetch("chat_id"), "topic_id" => route["topic_id"] }
        end
      end

      def change
        @migration&.claim
        document = @store.change do |document|
          defaults(document)
          yield(document)
        end
        @migration&.complete
        document
      end

      def bind(bot_id)
        change do |document|
          held = document["bot_id"]
          if held && held != bot_id.to_s
            raise Rho::ConfigurationError, "telegram: this Agent profile is bound to another bot; use a different Agent"
          end
          document["bot_id"] = bot_id.to_s
          # A formal POST in flight at process death may already have reached Telegram.
          document.fetch("deliveries").each_value do |delivery|
            delivery["status"] = "uncertain" if delivery["status"] == "sending"
          end
        end
      end

      def stage(update)
        change { |document| document["pending_update"] ||= update }
        read.fetch("pending_update")
      end

      def consumed(update_id)
        change do |document|
          document["offset"] = update_id + 1
          document.delete("pending_update")
        end
      end

      def enqueue(key, route:, text:, **attributes)
        change do |document|
          document.fetch("deliveries")[key] ||= {
            "status" => "pending", "chat_id" => route.fetch("chat_id"),
            "topic_id" => route["topic_id"], "group" => route.fetch("group"), "text" => text,
            "route_key" => route["route_key"],
          }.merge(attributes.transform_keys(&:to_s))
        end
      end
    end
  end
end
