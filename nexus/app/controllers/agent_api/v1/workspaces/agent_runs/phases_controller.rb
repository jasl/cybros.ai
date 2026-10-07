# How far a run has come — the authored phases in write order, the one in
# flight, the background work and the spend — derived from rows that
# already exist. Reading is the only verb. Named for what it answers
# (`phases`): `progress` is the executor plane's ephemeral feed, and one
# word carries one meaning on the wire.
class AgentAPI::V1::Workspaces::AgentRuns::PhasesController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    agent_run = find_listable_loop(@workspace)
    render json: AgentAPI::AgentRunPhasesPresenter.call(agent_run).to_h
  end
end
