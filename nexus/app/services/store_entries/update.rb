module StoreEntries
  # No host lock: the entry's lock_version CAS decides, and a write
  # straddling an archive is as if committed just before it.
  class Update
    include Authority

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(entry:, by:, lock_version:, value:)
      @entry = entry
      @by = by
      @lock_version = lock_version
      @value = value
    end

    def call
      fresh = StoreEntry.find_by(id: @entry.id)
      refusal = fresh&.host&.store_write_refusal(@by)

      if fresh.nil? || refusal
        Result.blocked(refusal || :not_found)
      else
        fresh.lock_version = @lock_version
        fresh.value = @value

        if fresh.save
          Result.done(:updated, fresh)
        else
          Result.invalid(fresh)
        end
      end
    rescue ActiveRecord::StaleObjectError
      Result.blocked(:stale_object)
    end
  end
end
