module MemoryCollections
  class Create
    def self.call(owner:, scope:, by:, attributes:, speaker: nil, default: false)
      owner.with_lock("FOR NO KEY UPDATE") do
        next MemoryCollection::Result.refused(:not_authorized) unless Access.new(by: by).owner_manageable?(owner, scope: scope)
        next MemoryCollection::Result.refused(:memory_scope_unavailable) if default && (scope != :speaker || speaker.nil?)

        if default
          collection = MemoryCollection.default_for(owner, speaker: speaker)
          next MemoryCollection::Result.refused(:memory_scope_unavailable) if collection.deleted?
        else
          collection = owner.memory_collections.create(**attributes, speaker: speaker)
        end
        collection.persisted? ? MemoryCollection::Result.accepted(collection) : MemoryCollection::Result.invalid(collection)
      end
    end
  end
end
