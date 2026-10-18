# Standalone runs have an events channel; conversation runs use their
# conversation's stream.
class AgentAPI::V1::RunEventsChannel < AgentAPI::V1::EventsChannel
  private

    def browser_session_allowed? = true

    # A standalone run has no ACL of its own: no funnel to read.
    def find_host(workspace, _user)
      run = Run.where(workspace_id: workspace.id).listable
        .find_by(public_id: params[:run_id])
      run if run&.standalone?
    end
end
