module AgentAPI
  # Basic omits `value` so an omitted list value can never be confused with a
  # stored JSON null; Full carries it. One shape for the three hosts: no host
  # field rides the wire — the route says whose store it is.
  class StoreEntryPresenter
    class << self
      def basic(entry)
        {
          public_id: entry.public_id,
          namespace: entry.namespace,
          key: entry.key,
          lock_version: entry.lock_version,
          created_at: entry.created_at,
          updated_at: entry.updated_at,
        }
      end

      def full(entry)
        basic(entry).merge(value: entry.value)
      end
    end
  end
end
