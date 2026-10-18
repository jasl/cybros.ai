class API::V1::McpConnections::BaseController < API::V1::BaseController
  include McpConnectionParameters

  before_action :load_connection

  private

    def load_connection
      @connection = Current.user.mcp_connections.find_by!(public_id: params[:mcp_connection_id] || params[:id])
    end

    def expected_version(fields)
      bounded_integer(fields[:lock_version], :lock_version, range: 0..2_147_483_647)
    end

    def render_connection_result(result, status: :ok)
      if result.success?
        render json: { mcp_connection: API::McpConnectionPresenter.full(result.connection) }, status: status
      elsif result.outcome == :invalid
        render_error(:validation_failed, result.connection.errors.full_messages.to_sentence, status: :unprocessable_entity)
      else
        render_refusal(result.outcome)
      end
    end
end
