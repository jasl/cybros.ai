module NexusDoubles
  class FakeAgentApi
    private

      def mcp_connections_response(params)
        principal = params["agent_public_id"] || @user_public_id
        unless principal == @user_public_id || @named_agents.any? { |row|
          row.fetch("public_id") == principal && row.fetch("derived_from_public_id") == @user_public_id && row["status"] != "removed"
        }
          return respond(404, { "error" => { "code" => "not_found", "message" => "Agent is unavailable" } })
        end

        rows = @mcp_connections.fetch(@user_public_id, []).sort_by { |row| row.fetch("public_id") }
        rows = rows.reverse if params["order"] == "desc"
        after = params["after"]
        rows = rows.drop_while { |row| row.fetch("public_id") != after }.drop(1) if after
        limit = Integer(params.fetch("limit", 25))
        page = rows.first(limit)
        respond(200, { "mcp_connections" => page,
          "pagination" => { "next_after" => (page.last.fetch("public_id") if rows.length > limit) } })
      end
  end
end
