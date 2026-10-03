# The loop's mirror: the one events channel over the listable STANDALONE
# loop — a loop-backed loop's stream is its conversation's, and it
# rejects like absence.
class AgentAPI::V1::AgentLoopEventsChannel < AgentAPI::V1::EventsChannel
  private

    # A standalone loop has no ACL of its own: no funnel to read.
    def find_host(workspace, _user)
      agent_loop = AgentLoop.where(workspace_id: workspace.id).listable
        .find_by(public_id: params[:agent_loop_id])
      agent_loop if agent_loop&.standalone?
    end
end
