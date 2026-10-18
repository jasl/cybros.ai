class API::V1::Agents::Executors::BaseController < API::V1::Agents::BaseController
  private

    def api_keys
      @agent.executor_api_keys
    end
end
