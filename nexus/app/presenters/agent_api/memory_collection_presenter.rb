module AgentAPI
  class MemoryCollectionPresenter
    def self.full(collection, access:)
      metadata(collection).merge(writable: access.writable?(collection), manageable: access.manageable?(collection))
    end

    def self.metadata(collection)
      { public_id: collection.public_id, name: collection.name, description: collection.description,
        scope: collection.natural_scope, owner_public_id: collection.owner.public_id,
        speaker_public_id: collection.speaker&.public_id, is_default: collection.is_default,
        archived_at: collection.archived_at, lock_version: collection.lock_version,
        created_at: collection.created_at, updated_at: collection.updated_at }
    end
  end
end
