class API::V1::McpConnections::CredentialsController < API::V1::McpConnections::BaseController
  def update
    fields = params.expect(credential: [:lock_version, :bearer_token])
    render_connection_result(@connection.set_credential(bearer_token: fields.fetch(:bearer_token).to_s,
      expected_lock_version: expected_version(fields)))
  end

  def destroy
    fields = params.expect(command: [:lock_version])
    render_connection_result(@connection.set_credential(bearer_token: nil,
      expected_lock_version: expected_version(fields)))
  end
end
