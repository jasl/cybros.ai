# Account-level model operations are owned by Human administrators.
# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelProvidersController < API::V1::Admin::ModelProviders::BaseController
  # @oas_include
  # @summary List model providers
  # @tags Platform, model providers
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersIndex
  # @response_ref (503) #/components/responses/APIError
  def index
    render json: {
      model_providers: AgentAPI::ModelProviderPresenter.index(
        account: account, snapshot: snapshot, now: DatabaseClock.now
      ),
    }
  end

  # @oas_include
  # @summary Read model providers
  # @tags Platform, model providers
  # @parameter id(path) [!String] Resource selector.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersShow
  # @response_ref (503) #/components/responses/APIError
  def show
    render_configuration
  end
end
