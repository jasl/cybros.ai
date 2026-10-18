class API::V1::Agents::APIKeysController < API::V1::Agents::BaseController
  include API::V1::Agents::APIKeyActions

  private

    def api_keys = @agent.api_keys

    def issue_key(name:, note:)
      AccessTokens::IssueAPIKey.call(user: @agent, name: name, note: note)
    end
end
