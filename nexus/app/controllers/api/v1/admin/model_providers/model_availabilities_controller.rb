# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelProviders::ModelAvailabilitiesController < API::V1::Admin::ModelProviders::BaseController
  # @oas_include
  # @summary Update model availabilities
  # @tags Platform, model availabilities
  # @parameter model_provider_id(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/ApiV1AdminModelProvidersModelAvailabilitiesUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersModelAvailabilitiesUpdate
  def update
    fields = params.expect(command: [:model, :available, :expected_lock_version])
    available = fields[:available]
    # This command shares the visibility API's strict JSON boolean contract.
    return render_error(:parameter_invalid, "available must be true or false",
      status: :bad_request) unless [true, false].include?(available)

    model = fields[:model].to_s
    catalog = ModelSelection::Resolver.effective_provider_catalog(account, snapshot, provider_id)
    return render_not_found unless ModelProviderConfig.provider_lane_ref?(provider_id, model) && catalog.models.key?(model)

    result = ModelProviders::SetModelAvailability.call(
      account: account, provider_id: provider_id, model_ref: model,
      available: available, expected_lock_version: expected_version(fields)
    )
    return render_lane if result.done?

    case result.outcome
    when :not_found then render_not_found
    when :stale then render_error(:stale_object, "The lane changed since you read it", status: :conflict)
    else render_error(:validation_failed, "The model availability could not be changed", status: :unprocessable_entity)
    end
  end
end
