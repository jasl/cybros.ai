module Rho
  module T3
    # One bounded current value per delegated work item, in its conversation.
    # Final result content belongs to the ToolTask; this is only continuation
    # and environment identity. Forked records retain their original owner.
    class Records
      NAMESPACE = "rho.t3".freeze

      def initialize(store:, conversation:)
        @store = store
        @conversation = conversation
      end

      def find(key)
        after = nil
        loop do
          page = @store.list(limit: 100, after: after)
          row = page.items.find { |entry| entry.namespace == NAMESPACE && entry.key == key }
          return fetch(row.public_id) if row
          return nil unless page.next_after

          after = page.next_after
        end
      end

      def fetch(id)
        row = @store.fetch(id)
        unless row.namespace == NAMESPACE && row.value.fetch("conversation") == @conversation
          raise Error, "coding work belongs to another conversation"
        end
        row
      end

      def list
        @store.list(limit: 100).items.select { |row| row.namespace == NAMESPACE }.filter_map do |row|
          entry = @store.fetch(row.public_id)
          next unless entry.value.fetch("conversation") == @conversation

          { "work_id" => entry.public_id, "title" => entry.value.fetch("title", "Coding assignment"),
            **entry.value.fetch("selection", {}).slice("agent", "harness", "model") }
        end
      end

      def create(key, value)
        @store.create(namespace: NAMESPACE, key: key, value: value.merge("conversation" => @conversation),
          idempotency_key: "t3:#{key}").store_entry
      end

      def update(row, **changes)
        @store.update(row.public_id, value: row.value.merge(changes.transform_keys(&:to_s)), lock_version: row.lock_version)
      end

      def delete(row)
        @store.delete(row.public_id, lock_version: row.lock_version)
      end
    end
  end
end
