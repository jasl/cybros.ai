# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelProviders::ModelDiscoveriesController < API::V1::Admin::ModelProviders::BaseController
  # @oas_include
  # @summary Create model discoveries
  # @tags Platform, model discoveries
  # @parameter model_provider_id(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/ApiV1AdminModelProvidersModelDiscoveriesCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersModelDiscoveriesCreate
  def create
    fields = params.expect(command: [:expected_lock_version])
    result = ModelProviders::DiscoverModels.call(
      account: account, provider_id: provider_id, expected_lock_version: expected_version(fields)
    )
    return render json: { models: result.models } if result.success?

    if result.outcome == :stale
      render_error(:stale_object, "The provider changed since you read it", status: :conflict)
    else
      render_error(:validation_failed, "Model discovery failed: #{result.outcome}", status: :unprocessable_entity)
    end
  end
end
