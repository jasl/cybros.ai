module E2E
  module MemoryCollections
    # Tests discover fixed collection identities through the public API. Reads
    # never initialize a default, and a missing default is a test failure.
    def self.default_documents(owner)
      collection = owner.memory_collections.list(default: true).items.fetch(0)
      owner.memory_collections.documents(collection.public_id)
    end

    def self.create_condition(memory, path)
      binding = memory.bindings.fetch("bindings").find { |row| row.fetch("name") == path.split("/", 2).first }
      { expected_collection_public_id: binding.fetch("collection_public_id") }
    end
  end
end
