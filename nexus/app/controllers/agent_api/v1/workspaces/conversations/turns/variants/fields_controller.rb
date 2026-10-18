class AgentAPI::V1::Workspaces::Conversations::Turns::Variants::FieldsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    conversation = find_listable_conversation(@workspace)
    options = ::Conversations::History::Parameters.field(params.permit(:field, :location, :after).to_h)
    result = ::Conversations::Reader.new(conversation, user: acting_user).field(
      turn_public_id: params.fetch(:turn_public_id), variant_public_id: params.fetch(:variant_public_id), **options)
    render json: result
  rescue ::Conversations::History::Parameters::Invalid => error
    render_error(:parameter_invalid, error.message, status: :bad_request)
  end
end
