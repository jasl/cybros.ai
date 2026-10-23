module CybrosAgent
  module Api
    MemoryCollection = Data.define(:public_id, :name, :description, :scope, :owner_public_id, :speaker_public_id,
      :is_default, :archived_at, :lock_version, :created_at, :updated_at, :writable, :manageable)

    class MemoryCollectionsContext
      include WorkspaceProjections
      include Fields

      PATH = "/agent_api/v1/memory_collections".freeze

      def initialize(dispatch:, path: PATH)
        @dispatch = dispatch
        @path = path
      end

      def list(after: nil, limit: nil)
        page(MemoryCollection, @dispatch.call(@path, params: query(after:, limit:)), "memory_collections")
      end

      def fetch(public_id)
        shape(MemoryCollection, @dispatch.call(collection_path(public_id)), "memory_collection")
      end

      def update(public_id, lock_version:, name: UNSET, description: UNSET)
        body = fields(lock_version:, name:, description:)
        shape(MemoryCollection, @dispatch.call(collection_path(public_id), method: :patch,
          body: { "memory_collection" => body }), "memory_collection")
      end

      def archive(public_id, lock_version:) = lifecycle(public_id, "archive", lock_version)
      def restore(public_id, lock_version:) = lifecycle(public_id, "restore", lock_version)

      def delete(public_id, lock_version:)
        @dispatch.call(collection_path(public_id), method: :delete, success: 204,
          body: { "memory_collection" => { "lock_version" => lock_version } })
        nil
      end

      def documents(public_id)
        MemoryDocumentsContext.new(dispatch: @dispatch, path: "#{collection_path(public_id)}/documents")
      end

      SHAPES = {
        MemoryCollection => {
          public_id: :string, name: :nullable_string, description: :nullable_string, scope: :string, owner_public_id: :string,
          speaker_public_id: :optional_string, is_default: :boolean, archived_at: :optional_string,
          lock_version: :integer, created_at: :string, updated_at: :string, writable: :boolean, manageable: :boolean,
        },
      }.freeze

      private

        def collection_path(public_id) = "#{PATH}/#{path_segment(public_id, "public_id")}"

        def lifecycle(public_id, action, lock_version)
          shape(MemoryCollection, @dispatch.call("#{collection_path(public_id)}/#{action}", method: :post,
            body: { "memory_collection" => { "lock_version" => lock_version } }), "memory_collection")
        end
    end

    # Owner-scoped discovery and creation. All later operations use the UUID.
    class OwnedMemoryCollectionsContext < MemoryCollectionsContext
      def list(after: nil, limit: nil, default: nil, speaker_public_id: nil)
        page(MemoryCollection, @dispatch.call(@path, params: query(after:, limit:, default:, speaker_public_id:)), "memory_collections")
      end

      def create(name: nil, description: nil, speaker_public_id: nil, default: false)
        body = { "name" => name, "description" => description, "speaker_public_id" => speaker_public_id,
                 "default" => default }.compact
        shape(MemoryCollection, @dispatch.call(@path, method: :post, success: [200, 201],
          body: { "memory_collection" => body }), "memory_collection")
      end
    end
  end
end
