module StoreEntries
  # StoreEntry writes are data, not management, on every host; no access
  # conceals the host exactly like absence. The host answers its own
  # refusal (StoreHost#store_write_refusal); this module holds only the
  # result the three services share.
  module Authority
    Result = Data.define(:outcome, :entry, :errors) do
      class << self
        def done(outcome, entry)
          new(outcome: outcome, entry: entry, errors: nil)
        end

        def blocked(reason)
          new(outcome: reason, entry: nil, errors: nil)
        end

        def invalid(record)
          new(outcome: :invalid, entry: nil, errors: record.errors)
        end
      end
    end
  end
end
