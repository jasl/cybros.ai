# Stop the running reply — the plane's cancellation verb.
class AgentAPI::V1::Workspaces::Conversations::CancellationsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

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
