# An accepted input's original turn/candidate survives the waiting-room row
# and event retention. This read derives that identity without selecting a
# later edit, regeneration, or currently active candidate.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Inputs::MaterializationsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read materializations
  # @tags Member, materializations
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter input_public_id(path) [!String] Public UUIDv7. format: (uuid)
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsInputsMaterializationsShow
  def show
    conversation = find_listable_conversation(@workspace)
    entry = conversation.timeline.materialized_entry(input_public_id: params.fetch(:input_public_id),
      include_hidden: cast_boolean(params[:include_hidden]))
    raise ActiveRecord::RecordNotFound if entry.nil?

    variant = entry.turn.variants.live.find_by(position: 0)
    raise ActiveRecord::RecordNotFound if variant.nil?

    render json: {
      materialization: AgentAPI::ConversationPresenter.materialization(
        entry.turn, variant, variant.run
      ),
    }
  end
end
