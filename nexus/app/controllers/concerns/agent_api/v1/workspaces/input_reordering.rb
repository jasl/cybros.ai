# THE EXACT-SET REORDER of a host's waiting room, one body over both doors:
# not a move — the server refuses a list that is not a permutation of what
# is queued, so a reorder racing an arrival cannot silently drop the
# arrival. A door's `reorders` controller includes it and inherits the
# door's host lookup.
module AgentAPI::V1::Workspaces::InputReordering
  extend ActiveSupport::Concern

  def create
    host = self.host
    ordered = params.expect(inputs: [])
    raise APIErrors::ParameterInvalid, :inputs unless ordered.all? { |id| ConversationInput.uuid_shaped?(id) }

    result = ::Conversations::Inputs::Reorder.call(::Conversations::Inputs::Reorder::Command.new(
      host: host,
      ordered_public_ids: ordered,
      acting_user: acting_user,
    ))

    if result.accepted?
      render json: {
        inputs: result.value.map { |input| AgentAPI::ConversationPresenter.input(input.reload) },
      }
    else
      render_refusal(result.outcome)
    end
  end
end
