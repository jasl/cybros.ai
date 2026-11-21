# @auth [PlatformBearer, BrowserSession]
class API::V1::Agents::Budgets::EntriesController < API::V1::Agents::BudgetsController
  # @oas_include
  # @summary List entries
  # @tags Platform, entries
  # @parameter agent_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter budget_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AgentsBudgetsEntriesIndex
  def index
    render_budget_entries
  end
end
