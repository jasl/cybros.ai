class AgentAPI::V1::Workspaces::Conversations::HistoriesController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    conversation = find_listable_conversation(@workspace)
    options = ::Conversations::History::Parameters.read(params.to_unsafe_h)
    render json: ::Conversations::History::Read.call(conversation: conversation, **options)
  rescue ::Conversations::History::Parameters::Invalid => error
    render_error(:parameter_invalid, error.message, status: :bad_request)
  end
end
