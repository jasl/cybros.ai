# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Turns::Variants::ReasoningsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read reasonings
  # @tags Member, reasonings
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter turn_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter variant_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsVariantsReasoningsShow
  # @response_ref (410) #/components/responses/APIError
  def show
    conversation = find_listable_conversation(@workspace)
    reach = ::Conversations::TurnReach.resolve(
      conversation: conversation, turn_public_id: params.fetch(:turn_public_id)
    )
    raise ActiveRecord::RecordNotFound if reach.nil?

    if reach.inherited?
      override = conversation.turn_overrides.find_by(turn_id: reach.turn.id)
      raise ActiveRecord::RecordNotFound if override&.deleted_at
    elsif reach.turn.deleted?
      raise ActiveRecord::RecordNotFound
    end
    variant = reach.turn.variants.live.find_by!(public_id: params.fetch(:variant_public_id))
    if variant.details_pruned_at || variant.run&.details_pruned_at
      return render_error(:execution_details_pruned,
        "Execution details have expired; the conversation text is retained", status: :gone)
    end

    render json: AgentAPI::ConversationReasoningPresenter.call(
      variant: variant, before: cursor_param(Task::TranscriptCursor, :before),
      limit: limit_param(default: AgentAPI::ConversationReasoningPresenter::DEFAULT_LIMIT,
        max: AgentAPI::ConversationReasoningPresenter::MAX_LIMIT)
    )
  end
end
