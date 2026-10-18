module StoreEntries
  # Real deletion under the same optimistic CAS as replacement: the guarded
  # single-statement delete treats zero affected rows as losing the race
  # (locking ladder rung 2). No host lock on any host.
  class Delete
    include Authority

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(entry:, by:, lock_version:)
      @entry = entry
      @by = by
      @lock_version = lock_version
    end

    def call
      fresh = StoreEntry.find_by(id: @entry.id)
      refusal = fresh&.host&.store_write_refusal(@by)

      if fresh.nil? || refusal
        Result.blocked(refusal || :not_found)
      elsif StoreEntry.where(id: fresh.id, lock_version: @lock_version).delete_all == 1
        Result.done(:deleted, fresh)
      else
        Result.blocked(:stale_object)
      end
    end
  end
end
