class AgentAPI::V1::Workspaces::Conversations::Turns::Variants::ReasoningsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    conversation = find_listable_conversation(@workspace)
    reach = ::Conversations::TurnReach.resolve(
      conversation: conversation, turn_public_id: params.fetch(:turn_public_id)
    )
    raise ActiveRecord::RecordNotFound if reach.nil?

    if reach.inherited?
      override = conversation.conversation_turn_overrides.find_by(conversation_turn_id: reach.turn.id)
      raise ActiveRecord::RecordNotFound if override&.deleted_at
    elsif reach.turn.deleted?
      raise ActiveRecord::RecordNotFound
    end
    variant = reach.turn.conversation_turn_variants.live.find_by!(public_id: params.fetch(:variant_public_id))
    if variant.details_pruned_at || variant.agent_run&.details_pruned_at
      return render_error(:execution_details_pruned,
        "Execution details have expired; the conversation text is retained", status: :gone)
    end

    render json: AgentAPI::ConversationReasoningPresenter.call(
      variant: variant, before: cursor_param(AgentRunTask::TranscriptCursor, :before),
      limit: limit_param(default: AgentAPI::ConversationReasoningPresenter::DEFAULT_LIMIT,
        max: AgentAPI::ConversationReasoningPresenter::MAX_LIMIT)
    )
  end
end
