class Admin::ModelProviders::ModelResetsController < Admin::ModelProviders::BaseController
  def create
    fields = params.expect(model_reset: [:model, :expected_lock_version])
    model = fields.fetch(:model).to_s
    raise ActiveRecord::RecordNotFound unless configuration.fetch(:models).any? { |row| row.fetch(:model) == model }

    result = ModelProviders::ResetModelOverride.call(account: account, provider_id: provider_id,
      model_ref: model, validate_definition: true, expected_lock_version: expected_lock_version(fields))
    if result.done?
      redirect_to admin_model_provider_path(provider_id), notice: "Model returned to its installation definition.", status: :see_other
    else
      redirect_to admin_model_provider_model_definition_path(provider_id, model: model),
        alert: result.outcome == :stale ? "Settings changed. Review the current model before trying again." : "The model could not be reset.", status: :see_other
    end
  end
end
