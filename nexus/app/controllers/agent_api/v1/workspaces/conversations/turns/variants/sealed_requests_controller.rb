# THE DEBUG DOOR: what this variant's model was sent — exactly the sealed
# entries and the request_options, read off the sealed body, never
# re-assembled. An inference variant's own invocation; a loop-backed
# variant's first round (every later round is the loop route's). Browse
# standing suffices: the workspace's own bytes.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Turns::Variants::SealedRequestsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read sealed requests
  # @tags Member, sealed requests
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsVariantsSealedRequestsShow
  # @response_ref (410) #/components/responses/APIError
  def show
    conversation = find_listable_conversation(@workspace)
    reach = ::Conversations::TurnReach.resolve(
      conversation: conversation, turn_public_id: params.fetch(:turn_public_id)
    )
    raise ActiveRecord::RecordNotFound if reach.nil?

    variant = reach.turn.variants.live
      .find_by!(public_id: params.fetch(:variant_public_id))
    if variant.details_pruned_at || variant.run&.details_pruned_at
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

      variant.run&.tasks
        &.find_by(node_key: ::Conversations::Inputs::ApplyNext::SEED_ROUND_KEY)
        &.selected_model_invocation
    end
end
