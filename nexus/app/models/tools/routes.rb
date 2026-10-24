module Tools
  # Live availability for one acceptance. Callers retain their own refusal
  # order and freeze the selected identities in their existing snapshots.
  class Routes
    attr_reader :executors, :connections

    def initialize(principal:, runner_ids:, connection_ids:)
      @principal = principal
      rows = Executor.providing(:runner).where(account_id: principal.account_id, public_id: runner_ids)
        .includes(:manager, agent: :steward).to_a
      @readiness = Executor.credential_readiness_for(rows)
      @executors = rows.index_by(&:public_id)
      @connections = McpConnection.where(account_id: principal.account_id, public_id: connection_ids)
        .includes(:owner).index_by(&:public_id)
    end

    def runner_eligible?(public_id)
      executors[public_id]&.eligible_for_role?(:runner, @principal, readiness: @readiness)
    end

    def runner_serves?(route)
      executors.fetch(route.fetch("runner_executor_public_id")).served?(route.fetch("tool_name"), role: :runner)
    end

    def mcp_refusal(entry)
      connection = connections[entry.fetch("connection_public_id")]
      return :mcp_connection_unavailable unless connection&.usable_by?(@principal)
      return :mcp_tool_unavailable unless connection.tool_available?(agent: @principal, name: entry.fetch("tool_name"))

      nil
    end
  end
end
