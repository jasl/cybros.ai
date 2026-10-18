class API::V1::Agents::PrivateRunners::APIKeysController < API::V1::Agents::PrivateRunners::BaseController
  include API::V1::Agents::APIKeyActions

  private

    def api_keys = @private_runner.api_keys

    def issue_key(name:, note:)
      AccessTokens::IssueAPIKey.call(user: nil, executor: @private_runner, name: name, note: note)
    end
end
