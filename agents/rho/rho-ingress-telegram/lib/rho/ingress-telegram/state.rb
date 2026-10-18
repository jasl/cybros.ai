require "rho/store_document"

module Rho
  module IngressTelegram
    # Channel routing, Telegram consumption and external delivery receipts.
    # Nexus remains the authority for accepted input and completed response bodies.
    class State
      def initialize(store:)
        @store = store
      end

      def read
        document = @store.read
        defaults(document || {})
      end

      def defaults(document)
        if document.fetch("pending_media", {}).any?
          raise Rho::StateError, Locales::ENGLISH.fetch("input_state_incompatible")
        end
        %w[routes speakers deliveries questions].each { |name| document[name] ||= {} }
        document["pending_inputs"] ||= {}
        document["rooms"] ||= {}
        document["requests"] ||= {}
        document["work"] ||= {}
        document["messages"] ||= {}
        document["job_bindings"] ||= {}
        document["access"] ||= { "allowed_users" => [], "allowed_chats" => [], "ignored_users" => [] }
        document
      end

      def status
        document = read
        {
          "chats" => document.fetch("routes").values.map { |route| [route.fetch("chat_id"), route["topic_id"]] }.uniq.length,
          "delivery_issues" => document.fetch("deliveries").filter_map do |key, entry|
            next unless %w[uncertain refused].include?(entry.fetch("status"))

            { "key" => key, "chat_id" => entry.fetch("chat_id"), "topic_id" => entry["topic_id"],
              "status" => entry.fetch("status"), "conversation_id" => entry["conversation_id"],
              "turn_id" => entry["turn_id"], "destination_agent_public_id" => entry["destination_agent_public_id"],
              "error_code" => entry["error_code"], "error" => entry["error"] }.compact
          end,
        }
      end

      def binding(conversation_id)
        route = read.fetch("routes").values.find { |row| row.fetch("conversations").key?(conversation_id) }
        if route
          label = "Telegram · Chat #{route.fetch("chat_id")}"
          label += " · Topic #{route.fetch("topic_id")}" if route["topic_id"]
          { "channel" => "telegram", "label" => label,
            "chat_id" => route.fetch("chat_id"), "topic_id" => route["topic_id"], "connection_public_id" => route["connection_public_id"] }
        end
      end

      def change
        @store.change do |document|
          defaults(document)
          yield(document)
        end
      end

      def recover_deliveries
        change do |document|
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
          pending = document.fetch("pending_update")
          raise Rho::StateError, "telegram: consumed update does not match its receipt" unless pending.fetch("update").fetch("update_id") == update_id

          pending["processed"] = true
        end
      end

      def acknowledge(offset, connection_public_id:)
        pending = read["pending_update"]
        return unless pending && pending["processed"] && pending["connection_public_id"] == connection_public_id &&
          pending.fetch("update").fetch("update_id") < offset

        change { |document| document.delete("pending_update") }
      end

      def enqueue(key, route:, text:, **attributes)
        change do |document|
          document.fetch("deliveries")[key] ||= {
            "status" => "pending", "chat_id" => route.fetch("chat_id"),
            "topic_id" => route["topic_id"], "group" => route.fetch("group"), "text" => text,
            "route_key" => route["route_key"],
            "connection_public_id" => route["connection_public_id"],
          }.merge(attributes.transform_keys(&:to_s))
        end
      end
    end
  end
end
