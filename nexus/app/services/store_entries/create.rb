module StoreEntries
  # One create over three hosts: the host's ladder-ordered locks serialize
  # the cap count on the host row (StoreHost#with_store_create_lock), the
  # host answers its refusal from the LOCKED writer's standing, and the
  # insert is the host association's.
  class Create
    include Authority

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(host:, by:, namespace:, key:, value: nil)
      @host = host
      @by = by
      @namespace = namespace
      @key = key
      @value = value
    end

    def call
      @host.with_store_create_lock(@by) do |writer|
        refusal = @host.store_write_refusal(writer)
        if refusal
          Result.blocked(refusal)
        elsif @host.store_entries.count >= StoreEntry::MAX_ENTRIES_PER_HOST
          Result.blocked(:entry_limit_reached)
        else
          insert
        end
      end
    end

    private

      def insert
        entry = @host.store_entries.new(namespace: @namespace, key: @key, value: @value)

        # Every create serializes on the host row, so the validation sees a
        # committed duplicate; a RecordNotUnique is a programmer error.
        if entry.save
          Result.done(:created, entry)
        elsif entry.errors.of_kind?(:key, :taken)
          Result.blocked(:key_taken)
        else
          Result.invalid(entry)
        end
      end
  end
end
