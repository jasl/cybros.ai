# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelProviders::ModelDefinitionsController < API::V1::Admin::ModelProviders::BaseController
  # @oas_include
  # @summary Update model definitions
  # @tags Platform, model definitions
  # @parameter model_provider_id(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/ApiV1AdminModelProvidersModelDefinitionsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersModelDefinitionsUpdate
  def update
    fields = params.expect(command: [:model, :expected_lock_version, definition: {}])
    result = ModelProviders::UpsertModelOverride.call(
      account: account, provider_id: provider_id, model_ref: fields[:model].to_s,
      model: fields.fetch(:definition).to_h, validate_definition: true,
      expected_lock_version: expected_version(fields)
    )
    render_configuration_result(result)
  end

  # @oas_include
  # @summary Destroy model definitions
  # @tags Platform, model definitions
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
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersModelDefinitionsDestroy
  def destroy
    change(ModelProviders::RemoveModelOverride)
  end

  # @oas_include
  # @summary Reset model definitions
  # @tags Platform, model definitions
  # @parameter model_provider_id(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/ApiV1AdminModelProvidersModelDefinitionsReset
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersModelDefinitionsReset
  def reset
    change(ModelProviders::ResetModelOverride)
  end

  private

    def change(command)
      fields = params.expect(command: [:model, :expected_lock_version])
      result = command.call(
        account: account, provider_id: provider_id, model_ref: fields[:model].to_s,
        validate_definition: true, expected_lock_version: expected_version(fields)
      )
      render_configuration_result(result)
    end
end
