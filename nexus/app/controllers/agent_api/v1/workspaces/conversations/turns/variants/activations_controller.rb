# The swipe switch: activate another settled candidate on the tail turn.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Turns::Variants::ActivationsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Create activations
  # @tags Member, activations
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsVariantsActivationsCreate
  def create
    conversation = find_listable_conversation(@workspace)

    result = ::Conversations::Variants::Activate.call(
      ::Conversations::Variants::Activate::Command.new(
        conversation: conversation,
        turn_public_id: params.fetch(:turn_public_id),
        variant_public_id: params.fetch(:variant_public_id),
        acting_user: acting_user,
      )
    )

    if result.accepted?
      render json: {
        variant: AgentAPI::ConversationPresenter.variant(
          result.value,
          body: result.value.content_bodies.find_by(role: "content"),
          active: true,
          loop: AgentAPI::ConversationPresenter.loop_block(result.value),
          prompt: result.value.content_bodies.find_by(role: "prompt")
        ),
      }
    else
      render_refusal(result.outcome)
    end
  end
end
