class API::V1::McpConnections::AuthorizationsController < API::V1::McpConnections::BaseController
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.public_id },
    with: -> { render_rate_limited(retry_after: 60) }

  def create
    no_store
    fields = params.expect(command: [:lock_version])
    result = McpConnections::OAuth::Start.call(connection: @connection,
      expected_lock_version: expected_version(fields),
      redirect_uri: settings_mcp_connection_authorization_callback_url(@connection))
    if result.success?
      render json: { authorization: API::McpConnectionPresenter.authorization(result) }
    else
      render_refusal(result.outcome)
    end
  end
end
