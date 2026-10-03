# Regenerate: the same request, a new sample beside the original —
# optionally on a different model. A loop-backed origin answers a
# loop-backed sibling: the 202 carries the new candidate's own loop
# block — its `agent_loop_public_id`, the feed's correlation key, its
# empty rounds and its `world` — through the one presenter read every
# deck door uses; an inference sibling has no loop and carries none.
class AgentAPI::V1::Workspaces::Conversations::Turns::RegenerationsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    conversation = find_listable_conversation(@workspace)
    fields = params.fetch(:regeneration, {}).permit(
      model: %i[model reasoning_effort], configuration: {}
    )
    provider_id, model_ref, reasoning_effort = split_model(fields[:model])

    result = ::Conversations::Turns::Regenerate.call(
      ::Conversations::Turns::Regenerate::Command.new(
        conversation: conversation,
        turn_public_id: params.fetch(:turn_public_id),
        acting_user: acting_user,
        provider_id: provider_id,
        model_ref: model_ref,
        reasoning_effort: reasoning_effort,
        request_options: fields[:configuration]&.to_h,
      )
    )

    if result.accepted?
      variant = result.value
      turn = variant.conversation_turn
      # No content yet; the seed the service copied onto the newborn
      # candidate (Regenerate#carry_prompt) rides the 202 by presence.
      render json: {
        turn: { public_id: turn.public_id, status: turn.status },
        variant: AgentAPI::ConversationPresenter.variant(
          variant, body: nil, active: false, loop: AgentAPI::ConversationPresenter.loop_block(variant),
          prompt: variant.content_bodies.find_by(role: "prompt")
        ),
      }, status: :accepted
    else
      render_refusal(result.outcome)
    end
  end
end
