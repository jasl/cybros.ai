class Settings::McpConnections::BaseController < Settings::BaseController
  include McpConnectionParameters

  before_action :load_connection

  private

    def load_connection
      @connection = Current.user.mcp_connections.find_by!(public_id: params[:mcp_connection_id] || params[:id])
    end

    def expected_version(fields)
      value = fields.fetch(:lock_version)
      version = Integer(value.to_s, 10)
      raise ArgumentError unless (0..2_147_483_647).cover?(version)

      version
    rescue ArgumentError
      raise ActionController::BadRequest, "lock_version must be a nonnegative integer"
    end

    def finish_change(result, template: :show)
      if result.success?
        redirect_to settings_mcp_connection_path(result.connection), notice: t("mcp_connections.saved")
      else
        @connection = result.connection
        flash.now[:alert] = t("mcp_connections.errors.#{result.outcome}")
        render template, status: result.outcome == :stale_object ? :conflict : :unprocessable_entity
      end
    end
end
