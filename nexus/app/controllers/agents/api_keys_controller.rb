class Agents::APIKeysController < Agents::BaseController
  include Agents::APIKeyManagement

  private

    def api_keys = @agent.api_keys
    def keys_path = agent_api_keys_path(@agent)
    def new_key_path = new_agent_api_key_path(@agent)
    def key_revocation_path(key) = agent_api_key_revocation_path(@agent, key)
    def key_kind = :member

    def issue_key(name:, note:)
      AccessTokens::IssueAPIKey.call(user: @agent, name: name, note: note)
    end
end
