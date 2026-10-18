class Workspaces::ConversationsController < Work::BaseController
  PAGE_SIZE = 20

  def index
    @list_options = params.permit(:workspace_public_id, :archived, :query, :after, :page, :answering_user_public_id).to_h
    @workspace = browsable_workspaces.find_by!(public_id: params.fetch(:workspace_public_id))
    @archive = params.fetch(:archived, "exclude").to_s
    raise APIErrors::ParameterInvalid, :archived unless %w[exclude include only].include?(@archive)

    @query = params[:query].to_s.strip
    scope = Conversation.visible_to(acting_user, workspace: @workspace).working
      .where(parent_conversation_public_id: nil)
    @answerers = current_account.users.where(id: scope.select(:answering_user_id)).order(:display_name, :public_id)
      .pluck(:display_name, :public_id)
    if @query.present?
      @search = Conversations::History::Search.call(workspace: @workspace, user: acting_user,
        **Conversations::History::Parameters.search(params.permit(:query, :archived, :after, :answering_user_public_id).to_h))
    else
      scope = scope.unarchived if @archive == "exclude"
      scope = scope.archived if @archive == "only"
      if params[:answering_user_public_id].present?
        scope = scope.where(answering_user_id: current_account.users.where(public_id: params[:answering_user_public_id]).select(:id))
      end
      @conversations_pagy, @conversations = pagy(:offset,
        scope.includes(:workspace, :answering_user, :active_turn).order(last_activity_at: :desc, public_id: :desc),
        limit: PAGE_SIZE)
    end
    render "conversations/index"
  rescue Conversations::History::Parameters::Invalid
    render_error(:parameter_invalid, t("conversation_console.invalid_filters"), status: :bad_request)
  end
end
