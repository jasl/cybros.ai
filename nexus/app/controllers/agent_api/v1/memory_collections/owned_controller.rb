class AgentAPI::V1::MemoryCollections::OwnedController < AgentAPI::V1::MemoryCollectionsController
  def create
    fields = params.expect(memory_collection: [:name, :description, :speaker_public_id, :default])
    speaker = if fields[:speaker_public_id].present?
      return render_refusal(:memory_scope_unavailable) unless owner_scope == :agent

      Speaker.find_by!(account_id: acting_user.account_id, public_id: fields[:speaker_public_id])
    end
    result = ::MemoryCollections::Create.call(owner: owner, scope: speaker ? :speaker : owner_scope, by: acting_user,
      attributes: { name: fields[:name], description: fields[:description] }, speaker: speaker,
      default: ActiveModel::Type::Boolean.new.cast(fields[:default]))
    render_result(result, status: result.collection&.previously_new_record? ? :created : :ok)
  end

  private

    def collections
      scope = owner.memory_collections.merge(super)
      if cast_boolean(params[:default])
        speaker = params[:speaker_public_id].present? ? Speaker.find_by!(account_id: acting_user.account_id, public_id: params[:speaker_public_id]) : nil
        scope = scope.where(is_default: true, speaker: speaker)
      end
      scope
    end
end
