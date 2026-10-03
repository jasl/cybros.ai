class API::V1::Admin::ModelProviders::ModelDefinitionsController < API::V1::Admin::ModelProviders::BaseController
  def update
    fields = params.expect(command: [:model, :expected_lock_version, definition: {}])
    result = ModelProviders::UpsertModelOverride.call(
      account: account, provider_id: provider_id, model_ref: fields[:model].to_s,
      model: fields.fetch(:definition).to_h, validate_definition: true,
      expected_lock_version: expected_version(fields)
    )
    render_configuration_result(result)
  end

  def destroy
    change(ModelProviders::RemoveModelOverride)
  end

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
