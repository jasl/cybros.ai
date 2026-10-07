module MemoryDocuments
  # Selects `bytesize` off the version row so choosing never detoasts
  # content. `created_at` is the content's age, not the pointer's: a fork's
  # inherited notes were not all written at the moment of the fork.
  class Listing
    Entry = Data.define(:path, :public_id, :lock_version, :bytesize, :description, :written_at)

    def self.call(documents:, path_prefix: nil, paths: nil)
      scoped = documents.joins(:memory_document_version).order(:name)
      unless path_prefix.blank?
        scoped = scoped.where("memory_documents.name LIKE ?",
          "#{ActiveRecord::Base.sanitize_sql_like(path_prefix)}%")
      end

      # Sorted by PATH after the pluck: a three-scope listing reads
      # scope-grouped, where `order(:name)` alone would interleave them.
      scoped.pluck(
        :conversation_id, :workspace_id, :user_id, :name, :description,
        :public_id, :lock_version,
        "memory_document_versions.bytesize", "memory_document_versions.created_at"
      ).flat_map do |conversation_id, workspace_id, user_id, name, description, public_id, lock_version, bytes, written_at|
        names = paths ? paths.call(conversation_id, workspace_id, user_id, name) :
          [MemoryDocument.path_for(name, conversation_id: conversation_id, workspace_id: workspace_id, user_id: user_id)]
        names.map do |path|
          Entry.new(
            path: path,
            public_id: public_id, lock_version: lock_version,
            bytesize: bytes, description: description, written_at: written_at
          )
        end
      end.sort_by(&:path)
    end
  end
end
