# Stop the running reply — the plane's cancellation verb.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::CancellationsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Create cancellations
  # @tags Member, cancellations
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (202) #/components/responses/Empty
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def create
    conversation = find_listable_conversation(@workspace)

    result = ::Conversations::Turns::Cancel.call(::Conversations::Turns::Cancel::Command.new(
      conversation: conversation,
      acting_user: acting_user,
    ))

    if result.accepted?
      head :accepted
    elsif result.outcome == :not_running
      render_error(:not_running, "No reply is running", status: :conflict)
    else
      render_refusal(result.outcome)
    end
  end
end
