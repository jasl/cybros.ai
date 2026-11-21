# THE EXACT-SET REORDER of a host's waiting room, one body over both doors:
# not a move — the server refuses a list that is not a permutation of what
# is queued, so a reorder racing an arrival cannot silently drop the
# arrival. A door's `reorders` controller includes it and inherits the
# door's host lookup.
module AgentAPI::V1::Workspaces::InputReordering
  extend ActiveSupport::Concern

  # @oas_include
  # @summary Create reorders
  # @tags Member, reorders
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/ConcernsAgentApiV1WorkspacesInputReorderingRbCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ConcernsAgentApiV1WorkspacesInputReorderingRbCreate
  def create
    host = self.host
    ordered = params.expect(inputs: [])
    raise APIErrors::ParameterInvalid, :inputs unless ordered.all? { |id| Input.uuid_shaped?(id) }

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
