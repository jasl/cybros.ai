class Settings::McpConnections::Authorizations::CallbacksController < Settings::McpConnections::Authorizations::BaseController
  prepend_before_action :protect_callback

  rate_limit to: 10, within: 1.minute, by: -> { Current.user.public_id },
    with: -> { redirect_to settings_mcp_connection_path(@connection), alert: t("mcp_connections.authorization_rate_limited") }

  def show
    result = McpConnections::OAuth::Finish.call(connection: @connection,
      callback_params: params.permit(:code, :state, :iss, :error, :error_description).to_h)
    if result.success?
      redirect_to settings_mcp_connection_path(@connection), notice: t("mcp_connections.authorized"), status: :see_other
    else
      redirect_to settings_mcp_connection_path(@connection), alert: t("mcp_connections.errors.#{result.outcome}"), status: :see_other
    end
  end

  private

    def protect_callback
      no_store
      response.headers["Referrer-Policy"] = "no-referrer"
    end
end
