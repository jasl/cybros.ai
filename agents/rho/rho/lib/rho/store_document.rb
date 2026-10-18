require "async/semaphore"
require "json"
require "securerandom"

module Rho
  # One application-owned JSON current value in a scoped Nexus store.
  # The cache belongs to this process; every change commits before it is exposed.
  # This is not a model memory document or a local persistence backend.
  class StoreDocument
    def initialize(store:, namespace:, key:)
      @store, @namespace, @key = store, namespace, key
      @lock = Async::Semaphore.new(1)
      @loaded = false
    end

    def read
      synchronized do
        load
        copy(@entry&.value)
      end
    end

    def change
      synchronized do
        load
        value = copy(@entry&.value) || {}
        yield value
        publish(value) unless @entry && value == @entry.value
        copy(@entry.value)
      end
    end

    private

      # State changes sometimes read another field of the current document.
      # Keep that same-fiber read reentrant while other async callers wait.
      def synchronized
        return yield if @owner.equal?(Fiber.current)

        @lock.acquire do
          @owner = Fiber.current
          begin
            yield
          ensure
            @owner = nil
          end
        end
      end

      def load
        return if @loaded

        collection = @store.call
        @entry = find_entry(collection)
        @loaded = true
      end

      def find_entry(collection)
        after = nil
        loop do
          page = collection.list(after: after, limit: 100)
          row = page.items.find { |candidate| candidate.namespace == @namespace && candidate.key == @key }
          return collection.fetch(row.public_id) if row

          after = page.next_after
          return nil unless after
        end
      end

      def publish(value)
        collection = @store.call
        @entry = if @entry
          collection.update(@entry.public_id, value: value, lock_version: @entry.lock_version)
        else
          collection.create(namespace: @namespace, key: @key, value: value, idempotency_key: SecureRandom.uuid).store_entry
        end
        @loaded = true
      rescue CybrosAgent::Api::RateLimited
        # This is an explicit rejection, not an unknown commit. A read against
        # the same spent resource budget cannot clarify it; the caller waits.
        raise
      rescue CybrosAgent::TransportError, CybrosAgent::Api::Error => error
        # A response may be lost after commit. Read the one authoritative value;
        # never replay a mutation against a newly fetched version. In particular,
        # a persisted sending marker must not become another external send.
        @loaded = false
        observed = find_entry(collection)
        if observed && observed.value == value
          @entry, @loaded = observed, true
          return
        end
        @entry = observed
        raise error
      end

      def copy(value)
        JSON.parse(JSON.generate(value)) unless value.nil?
      end
  end
end
