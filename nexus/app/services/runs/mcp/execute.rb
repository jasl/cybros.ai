module Runs
  module Mcp
    # The Task is the only durable execution owner. A committed start permits
    # one sender in that generation; a crashed sender is never replaced.
    class Execute
      def self.call(...) = new(...).call

      def initialize(node_id:, execution_generation:)
        @node_id = node_id
        @generation = execution_generation
      end

      def call
        @node = Task.find_by(id: @node_id)
        return if @node.nil? || !@node.mcp_call? || !unstarted?

        @run = @node.run
        @connection = @node.mcp_connection
        return fail_call(:mcp_connection_unavailable) if @connection.nil?
        return unless @run.running? && !SourceWork.execution_stopped?(@run)

        now = DatabaseClock.now
        return settle(timeout: true) if @node.deadline_passed?(@run.effective_now(now))
        return fail_call(:mcp_connection_unavailable) unless @connection.usable_by?(@run.answering_user)

        credential = McpConnections::OAuth::Credential.call(connection: @connection,
          timeout_seconds: @node.wall_deadline_at(now) - now)
        return fail_call(:mcp_authentication_failed) unless credential.success?

        case acquire
        when :started then execute
        when :expired then settle(timeout: true)
        when :unavailable then fail_call(:mcp_connection_unavailable)
        when nil then nil
        else raise "unknown MCP start outcome"
        end
      rescue ::Mcp::Error => error
        @connection.reject_oauth_credential(bearer_token: @bearer_token) if error.code == :mcp_authentication_failed
        fail_call(error.code, uncertain: error.request_sent, before_external_start: false)
      end

      private

        def unstarted?
          @node.status == "running" && @node.execution_generation == @generation && @node.external_started_at.nil?
        end

        def acquire
          principal = @run.answering_user
          ApplicationRecord.transaction do
            # Agent/steward changes and connection revocation must precede a
            # new external effect. The principal lane precedes connection/Run.
            PrincipalLocks.descend(principal)
            PrincipalLocks.descend(principal.steward, @connection.owner)
            @connection.lock!
            # Run serializes unique start with Stop, retry and duplicate jobs;
            # no IO or foreign-owner mutation occurs while these locks are held.
            @run.lock!
            @node.reload
            next unless unstarted? && @run.running? && !SourceWork.execution_stopped?(@run)
            next unless Deployments::Maintenance.admitting?

            now = DatabaseClock.now
            next :expired if @node.deadline_passed?(@run.effective_now(now))
            unless @run.workspace.data_writable_by?(@run.creating_user) &&
                @connection.tool_available?(agent: principal, name: @node.tool_name)
              next :unavailable
            end
            @bearer_token = @connection.current_bearer_token
            next :unavailable if @connection.auth_type == "oauth" && @bearer_token.nil?

            @node.start_external_call(now: now)
            @timeout_seconds = @node.wall_deadline_at(now) - now
            :started
          end
        end

        def execute
          endpoint = @connection.endpoint_url
          release_connection
          result = ::Mcp::Client.open(endpoint_url: endpoint, bearer_token: @bearer_token,
            timeout_seconds: @timeout_seconds, cancelled: method(:cancelled?)) do |client|
            client.call_tool(name: @node.tool_name, arguments: @node.tool_input)
          end
          adapted = ::Mcp::ResultContent.call(result: result, account: @node.account,
            creator: @run.answering_user)
          settle(outcome: "completed", **adapted)
        end

        # Pause freezes the task clock but cannot pause a remote service. Stop
        # and expiry end local IO best-effort at the transport's checkpoints;
        # its finite timeout still bounds a peer that sends no more bytes.
        def cancelled?
          ApplicationRecord.uncached do
            node = Task.find_by(id: @node_id)
            return true if node.nil? || node.execution_generation != @generation || node.terminal?

            run = node.run
            SourceWork.execution_stopped?(run) || run.canceling? || run.terminal? ||
              node.deadline_passed?(run.effective_now(DatabaseClock.now))
          end
        ensure
          release_connection
        end

        def fail_call(code, uncertain: false, before_external_start: true)
          settle(outcome: "failed", is_error: true, uncertain: uncertain, before_external_start: before_external_start,
            content: [{ "type" => "text", "text" => "#{code}: the MCP call could not produce a usable result." }])
        end

        def settle(**attributes)
          Parks::Settle.call(node: @node, execution_generation: @generation,
            trusted: true, creator: @run&.answering_user, **attributes)
        end

        def release_connection
          return if ApplicationRecord.connection_pool.active_connection?&.transaction_open?

          ApplicationRecord.connection_handler.clear_active_connections!
        end
    end
  end
end
