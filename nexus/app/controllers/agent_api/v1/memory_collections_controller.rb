class AgentAPI::V1::MemoryCollectionsController < AgentAPI::V1::Workspaces::BaseController
  def index
    page = keyset_page(collections, columns: { public_id: :uuid })
    access.preload(page.records)
    render json: { memory_collections: page.records.map { |row| projection(row) }, pagination: { next_after: page.next_after } }
  end

  def show
    render json: { memory_collection: projection(collection) }
  end

  def update
    fields = params.expect(memory_collection: [:name, :description, :lock_version])
    result = access.with_management(collection) do
      collection.update_metadata(fields.except(:lock_version), expected_lock_version: lock_version_from(fields))
    end
    render_result(result)
  end

  def destroy = lifecycle(:tombstone)

  private

    def access = @access ||= ::MemoryCollections::Access.new(by: acting_user)
    def collections = access.scope.includes(:workspace, :speaker, user: :derived_from, conversation: :workspace)
    def collection = @collection ||= collections.find_by!(public_id: params.fetch(:public_id))
    def projection(row) = AgentAPI::MemoryCollectionPresenter.full(row, access: access)

    def lifecycle(command)
      fields = params.expect(memory_collection: [:lock_version])
      result = access.with_management(collection) do
        collection.public_send(command, expected_lock_version: lock_version_from(fields))
      end
      if result.accepted? && command == :tombstone
        head :no_content
      else
        render_result(result)
      end
    end

    def render_result(result, status: :ok)
      if result.accepted?
        render json: { memory_collection: projection(result.collection) }, status: status
      else
        render_refused(result)
      end
    end
end
