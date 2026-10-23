module MemoryCollections
  # The URL fixes the collection; the path is relative to it. Content commands
  # share the same owner/collection locks as execution and lifecycle commands.
  class Documents
    def initialize(collection:, by:)
      @collection, @by = collection, by
    end

    def anchor(path)
      Scopes::Anchor::Result.new(collection: @collection, scope: @collection.natural_scope.to_s,
        name: path.to_s, refusal: nil)
    end

    def apply(path)
      @collection.with_mutation do
        selected = anchor(path)
        next MemoryDocuments::Write::Result.refused(selected.write_refusal) if selected.write_refusal
        next MemoryDocuments::Write::Result.refused(:not_authorized) unless Access.new(by: @by).writable?(@collection)

        yield selected
      end
    end
  end
end
