class Settings::McpConnections::CredentialsController < Settings::McpConnections::BaseController
  def show
  end

  def update
    fields = params.expect(credential: [:lock_version, :bearer_token])
    finish_change(@connection.set_credential(bearer_token: fields.fetch(:bearer_token).to_s,
      expected_lock_version: expected_version(fields)))
  end

  def destroy
    fields = params.expect(command: [:lock_version])
    finish_change(@connection.set_credential(bearer_token: nil, expected_lock_version: expected_version(fields)))
  end
end
