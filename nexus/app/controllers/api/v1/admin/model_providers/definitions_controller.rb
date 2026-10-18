class API::V1::Admin::ModelProviders::DefinitionsController < API::V1::Admin::ModelProviders::BaseController
  def update
    fields = params.expect(command: [:expected_lock_version, definition: {}])
    result = ModelProviders::SetDefinition.call(
      account: account, provider_id: given_provider_id, definition: fields.fetch(:definition).to_h,
      expected_lock_version: expected_version(fields)
    )
    render_configuration_result(result, id: given_provider_id)
  end

  def destroy
    fields = params.expect(command: [:expected_lock_version])
    result = ModelProviders::ResetDefinition.call(
      account: account, provider_id: configuration_provider_id, expected_lock_version: expected_version(fields)
    )
    render_configuration_result(result, id: configuration_provider_id)
  end
end
