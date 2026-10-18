class API::V1::Agents::Executors::APIKeysController < API::V1::Agents::Executors::BaseController
  include API::V1::Agents::APIKeyActions

  private

    def issue_key(name:, note:)
      AccessTokens::IssueAgentExecutorKey.call(agent: @agent, name: name, note: note)
    end
end
