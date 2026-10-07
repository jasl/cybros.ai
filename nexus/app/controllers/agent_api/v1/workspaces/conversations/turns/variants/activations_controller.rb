# The swipe switch: activate another settled candidate on the tail turn.
class AgentAPI::V1::Workspaces::Conversations::Turns::Variants::ActivationsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

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
