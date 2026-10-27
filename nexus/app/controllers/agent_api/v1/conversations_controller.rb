# Cross-workspace history uses the same visibility and pagination as the
# workspace collection. Application identity remains ordinary metadata.
class AgentAPI::V1::ConversationsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::ConversationListing

  def index
    scope = Conversation.visible_to(acting_user).working.lifecycle_roots
      .includes(:active_turn, :answering_user, :workspace)
    scope = filter_conversation_answerer(scope)
    if params.key?(:archived)
      unless %w[0 1 true false].include?(params[:archived].to_s)
        raise APIErrors::ParameterInvalid, :archived
      end
      archived = cast_boolean(params[:archived])
      scope = archived ? scope.archived : scope.unarchived
    end
    if params.key?(:metadata_key) || params.key?(:metadata_value)
      fields = params.permit(:metadata_key, :metadata_value)
      key = fields[:metadata_key].to_s
      value = fields[:metadata_value].to_s
      if key.empty? || key.bytesize > 128 || value.empty? || value.bytesize > 1024
        raise APIErrors::ParameterInvalid, :metadata_key
      end

      scope = scope.where("conversations.metadata @> ?::jsonb", { key => value }.to_json)
    end
    render_conversation_list(scope)
  end
end
