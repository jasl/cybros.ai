# THE DEBUG DOOR: what this variant's model was sent — exactly the sealed
# entries and the request_options, read off the sealed body, never
# re-assembled. An inference variant's own invocation; a loop-backed
# variant's first round (every later round is the loop route's). Browse
# standing suffices: the workspace's own bytes.
class AgentAPI::V1::Workspaces::Conversations::Turns::Variants::SealedRequestsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    conversation = find_listable_conversation(@workspace)
    reach = ::Conversations::TurnReach.resolve(
      conversation: conversation, turn_public_id: params.fetch(:turn_public_id)
    )
    raise ActiveRecord::RecordNotFound if reach.nil?

    variant = reach.turn.conversation_turn_variants.live
      .find_by!(public_id: params.fetch(:variant_public_id))
    if variant.details_pruned_at || variant.agent_run&.details_pruned_at
      return render_error(:execution_details_pruned,
        "Execution details have expired; the conversation text is retained", status: :gone)
    end
    invocation = sealed_invocation(variant)
    if invocation.nil?
      return render_error(:request_not_sealed, "This variant has no sealed request", status: :not_found)
    end

    render json: AgentAPI::SealedRequestPresenter.call(invocation)
  end

  private

    def sealed_invocation(variant)
      return variant.model_invocation if variant.model_invocation_id

      variant.agent_run&.agent_run_tasks
        &.find_by(node_key: ::Conversations::Inputs::ApplyNext::SEED_ROUND_KEY)
        &.selected_model_invocation
    end
end
