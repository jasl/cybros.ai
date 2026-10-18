module RunsHelper
  def run_console_parameters
    params.permit(:after, :before, :prefix, :limit, :order, :return_to).to_h
  end

  def run_refresh_data(run)
    host = run.host
    {
      controller: "work-refresh",
      work_refresh_channel_value: run.standalone? ? "AgentAPI::V1::RunEventsChannel" : "AgentAPI::V1::ConversationEventsChannel",
      work_refresh_workspace_id_value: run.workspace.public_id,
      work_refresh_resource_id_value: host.public_id,
    }
  end

  # The graph presenter has already closed the page's edges. The kernel's DAG
  # invariant makes dependency depth sufficient for this small, bounded view.
  def run_graph_positions(graph)
    parents = graph.edges.group_by(&:to)
    depths = {}
    depth = lambda do |key|
      depths[key] ||= parents.fetch(key, []).map { |edge| depth.call(edge.from) + 1 }.max || 0
    end
    lanes = Hash.new(0)
    graph.nodes.to_h do |node|
      level = depth.call(node.key)
      lane = lanes[level]
      lanes[level] += 1
      [node.key, [20 + lane * 230, 20 + level * 110]]
    end
  end

  def run_graph_edge_path(edge, positions)
    from_x, from_y = positions.fetch(edge.from)
    to_x, to_y = positions.fetch(edge.to)
    if to_y - from_y > 110
      # Skip-level dependencies travel through the outer gutter, so a node
      # between their endpoints cannot hide the edge.
      gutter = positions.values.map(&:first).max + 215
      "M #{from_x + 95} #{from_y + 65} V #{from_y + 85} H #{gutter} V #{to_y - 20} H #{to_x + 95} V #{to_y}"
    else
      "M #{from_x + 95} #{from_y + 65} C #{from_x + 95} #{from_y + 90}, #{to_x + 95} #{to_y - 25}, #{to_x + 95} #{to_y}"
    end
  end
end
