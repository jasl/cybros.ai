class AgentAPI::V1::RunsController < AgentAPI::V1::Workspaces::BaseController
  include RunListing

  def index
    scope = filtered_runs(Run.visible_to(acting_user, workspace: selected_workspace))
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: {
      runs: AgentAPI::RunPresenter.basic_many(page.records),
      pagination: { next_after: page.next_after },
    }
  end
end
