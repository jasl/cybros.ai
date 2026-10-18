class Agents::PrivateRunners::APIKeysController < Agents::PrivateRunners::BaseController
  include Agents::APIKeyManagement

  private

    def api_keys = @private_runner.api_keys
    def keys_path = agent_private_runner_api_keys_path(@agent, @private_runner)
    def new_key_path = new_agent_private_runner_api_key_path(@agent, @private_runner)
    def key_revocation_path(key) = agent_private_runner_api_key_revocation_path(@agent, @private_runner, key)
    def key_kind = :runner

    def issue_key(name:, note:)
      AccessTokens::IssueAPIKey.call(user: nil, executor: @private_runner, name: name, note: note)
    end
end
