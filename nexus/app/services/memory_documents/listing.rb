module MemoryDocuments
  # Selects `bytesize` off the version row so choosing never detoasts
  # content. `created_at` is the content's age, not the pointer's: a fork's
  # inherited notes were not all written at the moment of the fork.
  class Listing
    Entry = Data.define(:path, :collection_public_id, :public_id, :lock_version, :bytesize, :description, :written_at)

    def self.call(documents:, path_prefix: nil, paths: nil)
      scoped = documents.joins(:memory_document_version, :memory_collection).order("memory_documents.name")
      unless path_prefix.blank?
        scoped = scoped.where("memory_documents.name LIKE ?",
          "#{ActiveRecord::Base.sanitize_sql_like(path_prefix)}%")
      end

      # Sorted by PATH after the pluck: a three-scope listing reads
      # scope-grouped, where `order(:name)` alone would interleave them.
      scoped.pluck(
        :memory_collection_id, "memory_collections.public_id", "memory_documents.name", "memory_documents.description",
        "memory_documents.public_id", "memory_documents.lock_version",
        "memory_document_versions.bytesize", "memory_document_versions.created_at"
      ).flat_map do |collection_id, collection_public_id, name, description, public_id, lock_version, bytes, written_at|
        names = paths ? paths.call(collection_id, name) :
          ["#{MemoryCollection.find(collection_id).natural_scope}/#{name}"]
        names.map do |path|
          Entry.new(
            path: path, collection_public_id: collection_public_id,
            public_id: public_id, lock_version: lock_version,
            bytesize: bytes, description: description, written_at: written_at
          )
        end
      end.sort_by(&:path)
    end
  end
end
