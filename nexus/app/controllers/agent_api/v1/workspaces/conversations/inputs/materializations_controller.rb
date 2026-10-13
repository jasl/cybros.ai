# An accepted input's original turn/candidate survives the waiting-room row
# and event retention. This read derives that identity without selecting a
# later edit, regeneration, or currently active candidate.
class AgentAPI::V1::Workspaces::Conversations::Inputs::MaterializationsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    conversation = find_listable_conversation(@workspace)
    entry = conversation.timeline.materialized_entry(input_public_id: params.fetch(:input_public_id),
      include_hidden: cast_boolean(params[:include_hidden]))
    raise ActiveRecord::RecordNotFound if entry.nil?

    variant = entry.turn.conversation_turn_variants.live.find_by(position: 0)
    raise ActiveRecord::RecordNotFound if variant.nil?

    render json: {
      materialization: AgentAPI::ConversationPresenter.materialization(
        entry.turn, variant, variant.agent_run
      ),
    }
  end
end
