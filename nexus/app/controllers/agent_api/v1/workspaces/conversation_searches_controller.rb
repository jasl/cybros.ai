class AgentAPI::V1::Workspaces::ConversationSearchesController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    options = ::Conversations::History::Parameters.search(params.to_unsafe_h)
    render json: ::Conversations::History::Search.call(workspace: @workspace, user: acting_user, **options)
  rescue ::Conversations::History::Parameters::Invalid => error
    render_error(:parameter_invalid, error.message, status: :bad_request)
  end
end
