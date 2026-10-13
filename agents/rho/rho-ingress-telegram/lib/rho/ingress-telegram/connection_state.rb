module Rho
  module IngressTelegram
    # One physical platform identity owns its polling receipt and retry budget.
    class ConnectionState
      def initialize(store:) = @store = store
      def read = @store.read.to_h
      def change(&block) = @store.change(&block)

      def bind(bot_id)
        change do |document|
          held = document["bot_id"]
          if held && held != bot_id.to_s
            raise Rho::ConfigurationError, "telegram: this Connection is bound to another physical bot"
          end
          yield if block_given?
          document["bot_id"] = bot_id.to_s
        end
      end

      def stage(update:, agent_public_id:)
        change { |document| document["pending_update"] ||= { "update" => update, "agent_public_id" => agent_public_id } }
        read.fetch("pending_update")
      end

      def consumed(update_id)
        change do |document|
          document["offset"] = update_id + 1
          document.delete("pending_update")
        end
      end
    end
  end
end
