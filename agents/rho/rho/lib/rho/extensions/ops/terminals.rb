module Rho
  module Extensions
    module Ops
      module Terminals
        TASK_KEY = CybrosAgent::Api::RunContext::TOOL_CALL_TASK_KEY

        def self.register(api)
          api.register_route("POST", "/terminals") { |request, ctx| create(request, ctx) }
          api.register_route("GET", "/terminals") { |request, ctx| list(request, ctx) }
        end

        def self.create(request, ctx)
          ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
            runner = body["runner_executor_public_id"].to_s
            key = body["idempotency_key"].to_s
            next Rho::Daemon::Refusal.malformed("runner_executor_public_id and idempotency_key are required") if runner.empty? || key.empty?

            context = ctx.runs_for(client, workspace_public_id).start_tool_call(
              runner_executor_public_id: runner, tool: "terminal", input: {}, idempotency_key: key,
              approval_rules: Rho::RunDeclaration.request_rules(guard: ctx.config.plugin_enabled?("rho.guard"), roots: Rho.protected_roots(ctx.home))
            )
            [201, { terminal: { public_id: context.run_public_id, task_key: TASK_KEY, workspace_public_id: workspace_public_id } }]
          end
        end

        # Reopening uses Nexus records. A bounded page of standalone Runs is
        # inspected; there is no local terminal registry to lose on restart.
        def self.list(request, ctx)
          query = ControlServer.query(request)
          ctx.member_plane(request) do |client, workspace_public_id|
            runs = ctx.runs_for(client, workspace_public_id)
            page = runs.list(kind: "standalone", order: "desc", limit: 20, after: query["after"])
            rows = page.items.filter_map do |run|
              begin
                tasks = runs.run(run.public_id).fetch.tasks
              rescue CybrosAgent::Api::NotFound
                next
              end
              next unless tasks.length == 1 && tasks.first.key == TASK_KEY && tasks.first.tool_name == "terminal"

              { public_id: run.public_id, task_key: TASK_KEY, workspace_public_id: workspace_public_id,
                status: tasks.first.status, created_at: run.created_at }
            end
            [200, { terminals: rows, after: page.next_after, has_more: !page.next_after.nil? }]
          end
        end
      end
    end
  end
end
