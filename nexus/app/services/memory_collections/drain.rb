module MemoryCollections
  # The owner collector already holds its row and has checked its retention
  # obligations. Charge every document pointer and collection row to one budget;
  # immutable versions have their existing, independent orphan collector.
  class Drain
    def self.call(owner:, budget:)
      processed = 0
      ids = owner.memory_collections.order(:id).limit(budget).pluck(:id)
      ids.each do |id|
        break if processed == budget

        processed += collection(id: id, budget: budget - processed)
      end
      processed
    end

    def self.collection(id:, budget:)
      return 0 unless budget.positive?

      documents = MemoryDocument.where(memory_collection_id: id)
      document_ids = documents.order(:id).limit(budget).pluck(:id)
      processed = MemoryDocument.where(id: document_ids).delete_all
      if processed < budget && !documents.exists?
        processed += MemoryCollection.where(id: id).delete_all
      end
      processed
    end
  end
end
