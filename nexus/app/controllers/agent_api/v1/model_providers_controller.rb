# The provider lanes this account holds — the other half of `models`: a model
# runs only once its lane is enabled and credentialed by an administrator.
# @auth [MemberBearer]
class AgentAPI::V1::ModelProvidersController < AgentAPI::V1::BaseController
  serves_plane :member

  # @oas_include
  # @summary List model providers
  # @tags Member, model providers
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ModelProvidersIndex
  def index
    render json: {
      model_providers: AgentAPI::ModelProviderPresenter.index(
        account: current_credential.user.account, snapshot: ModelCatalog.current, now: DatabaseClock.now
      ),
    }
  end
end
