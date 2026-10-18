module AgentAPI
  class ExecutionExport
    module Tasks
      TaskPage = Data.define(:rows, :unavailable)
      TaskRecord = Data.define(:key, :task, :node, :request, :steer_body_id)

      private

        def execution(run, correlations, task_steers:)
          correlations = correlations.merge(run_public_id: run.public_id)
          ceiling, edge_ceiling = read { [run.tasks.maximum(:id), run.run_edges.maximum(:id)] }
          cursor = nil
          loop do
            page = read { task_page(run.id, ceiling, cursor, task_steers: task_steers) }
            if page.unavailable
              yield envelope("execution_unavailable", **correlations, reason: page.unavailable)
              break
            end
            rows = page.rows
            break if rows.empty?

            cursor = rows.last.key
            rows.each do |item|
              yield envelope("task", **correlations, task: item.task)
              yield envelope("graph_node", **correlations, node: item.node)
              if item.request
                yield envelope("request", **correlations, task_key: item.key, **item.request)
              end
              if item.steer_body_id
                steers(item.steer_body_id, correlations.merge(task_key: item.key)) do |record|
                  yield record
                end
              end
            end
          end
          edges(run.id, ceiling, edge_ceiling, correlations) { |record| yield record }
        end

        def task_page(run_id, ceiling, cursor, task_steers:)
          run = Run.listable.readable_by(@user).find_by(id: run_id)
          return TaskPage.new(rows: [], unavailable: "unavailable") if run.nil?
          return TaskPage.new(rows: [], unavailable: "execution_details_pruned") if run.details_pruned_at
          return TaskPage.new(rows: [], unavailable: nil) if ceiling.nil?

          scope = run.tasks.where(id: ..ceiling)
          scope = scope.where("node_key > ?", cursor) if cursor
          nodes = scope.order(:node_key).limit(DiagnosticExport::PAGE_SIZE)
            .preload(:sources, :addressed_executor, :target_executor, :mcp_connection, :approved_by_user).to_a
          ids = nodes.map(&:id)
          bodies = ContentBody.where(task_id: ids, role: %w[input output])
            .preload(content_body_entries: :content_fragment).group_by(&:task_id)
          steer_bodies = task_steers ? ContentBody.where(task_id: ids, role: "steers").pluck(:task_id, :id).to_h : {}
          invocations = nodes.filter_map(&:selected_model_invocation_id)
          request_bytes = ContentBody.where(model_invocation_id: invocations, role: "request")
            .pluck(:model_invocation_id, :byte_size).to_h
          requests = request_projections(invocations)
          declaring_keys = Runs::KernelTool.declaring_task_keys(nodes.select(&:tool_call?))
          parents = run.tasks.where(id: nodes.filter_map(&:expansion_parent_id)).where(id: ..ceiling)
            .pluck(:id, :node_key).to_h
          live_server_ids = NexusServer.live_ids
          rows = nodes.map do |node|
            node.association(:run).target = run
            owned = bodies.fetch(node.id, []).index_by(&:role)
            output = owned["output"]
            TaskRecord.new(
              key: node.node_key,
              task: AgentAPI::RunPresenter.detail(node, output: output&.effective_text,
                payloads: Runs::TaskResultProjection.entry_payloads(output), prompt: owned["input"]&.effective_text,
                live_server_ids: live_server_ids, declaring_task_key: declaring_keys[node.id],
                request_bytes: request_bytes[node.selected_model_invocation_id]),
              node: AgentAPI::RunGraphPresenter.node_projection(node,
                deliverable: node.id == run.deliverable_node_id, expansion_parent: parents[node.expansion_parent_id]).to_h,
              request: requests[node.selected_model_invocation_id],
              steer_body_id: steer_bodies[node.id],
            )
          end
          TaskPage.new(rows: rows, unavailable: nil)
        end

        def edges(run_id, task_ceiling, ceiling, correlations)
          cursor = nil
          while task_ceiling && ceiling
            page = read do
              run = Run.listable.readable_by(@user).where(details_pruned_at: nil).find_by(id: run_id)
              if run
                # The writer owns both endpoints within this Run, and their FKs
                # preserve existence. Bound their ids without rescanning its graph.
                bounded = run.run_edges.where(id: ..ceiling,
                  from_node_id: ..task_ceiling, to_node_id: ..task_ceiling)
                bounded = bounded.where("(from_node_id, to_node_id) > (?, ?)", *cursor) if cursor
                bounded.order(:from_node_id, :to_node_id).limit(DiagnosticExport::PAGE_SIZE).preload(:from_node, :to_node).map do |edge|
                  [[edge.from_node_id, edge.to_node_id], AgentAPI::RunGraphPresenter::Edge.new(from: edge.from_node.node_key,
                    to: edge.to_node.node_key, structural: edge.structural).to_h]
                end
              else
                []
              end
            end
            break if page.empty?

            cursor = page.last.first
            page.each { |_, projection| yield envelope("graph_edge", **correlations, edge: projection) }
          end
        end
    end
  end
end
