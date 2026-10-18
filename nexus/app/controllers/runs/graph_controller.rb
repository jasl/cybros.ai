class Runs::GraphController < Runs::BaseController
  def show
    @page = keyset_page(@run.tasks.includes(:incoming_edges), columns: { node_key: :text })
    @graph = AgentAPI::RunGraphPresenter.build(nodes: @page.records, deliverable_node_id: @run.deliverable_node_id)
  end
end
