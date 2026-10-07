# Regenerate: the same request, a new sample beside the original —
# optionally on a different model. A loop-backed origin answers a
# loop-backed sibling: the 202 carries the new candidate's own loop
# block — its `run_public_id`, the feed's correlation key, its
# empty rounds and its `runner_effects` — through the one presenter read every
# deck door uses; an inference sibling has no loop and carries none.
class AgentAPI::V1::Workspaces::Conversations::Turns::RegenerationsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    key = required_idempotency_key
    return if performed?

    conversation = find_listable_conversation(@workspace)
    fields = params.fetch(:regeneration, {}).permit(
      model: %i[model reasoning_effort reasoning_enabled], configuration: {}
    )
    turn_public_id = params.fetch(:turn_public_id)
    outcome = ConversationCommandReceipt::Idempotent.call(
      account: current_account, workspace: @workspace, acting_user: acting_user,
      operation: :regeneration, idempotency_key: key, host: conversation,
      request_digest: ConversationCommandReceipt.digest_for(
        operation: :regeneration, envelope: fields.to_h.merge("turn_public_id" => turn_public_id)
      )
    ) do
      regenerate(conversation, turn_public_id, fields)
    end

    render_idempotent_outcome(outcome)
  end

  private

    def regenerate(conversation, turn_public_id, fields)
      provider_id, model_ref, reasoning_effort, reasoning_enabled = split_model(fields[:model])
      result = ::Conversations::Turns::Regenerate.call(
        ::Conversations::Turns::Regenerate::Command.new(
          conversation: conversation, turn_public_id: turn_public_id, acting_user: acting_user,
          provider_id: provider_id, model_ref: model_ref, reasoning_effort: reasoning_effort, reasoning_enabled: reasoning_enabled,
          request_options: fields[:configuration]&.to_h
        )
      )
      return result unless result.accepted?

      variant = result.value
      turn = variant.conversation_turn
      # The receipt retains the original acceptance, even after completion:
      # a lost response must never turn a retry into another paid sample.
      ConversationCommandReceipt::Idempotent::Success.new(
        status: 202, host: conversation,
        body: {
          turn: { public_id: turn.public_id, status: turn.status },
          variant: AgentAPI::ConversationPresenter.variant(
            variant, body: nil, active: false, loop: AgentAPI::ConversationPresenter.loop_block(variant),
            prompt: variant.content_bodies.find_by(role: "prompt")
          ),
        }
      )
    end
end
