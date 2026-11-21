# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelProviders::DefinitionsController < API::V1::Admin::ModelProviders::BaseController
  # @oas_include
  # @summary Update definitions
  # @tags Platform, definitions
  # @parameter model_provider_id(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/ApiV1AdminModelProvidersDefinitionsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersDefinitionsUpdate
  def update
    fields = params.expect(command: [:expected_lock_version, definition: {}])
    result = ModelProviders::SetDefinition.call(
      account: account, provider_id: given_provider_id, definition: fields.fetch(:definition).to_h,
      expected_lock_version: expected_version(fields)
    )
    render_configuration_result(result, id: given_provider_id)
  end

  # @oas_include
  # @summary Destroy definitions
  # @tags Platform, definitions
  # @parameter model_provider_id(path) [!String] Resource selector.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersDefinitionsDestroy
  def destroy
    fields = params.expect(command: [:expected_lock_version])
    result = ModelProviders::ResetDefinition.call(
      account: account, provider_id: configuration_provider_id, expected_lock_version: expected_version(fields)
    )
    render_configuration_result(result, id: configuration_provider_id)
  end
end
