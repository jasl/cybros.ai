class Admin::ModelProviders::ModelVisibilitiesController < Admin::ModelProviders::BaseController
  before_action :load_models

  def show
  end

  def update
    fields = params.expect(model_visibility: [:model, :visible, :expected_lock_version])
    model = fields.fetch(:model).to_s
    raise ActiveRecord::RecordNotFound unless @models.any? { |row| row.fetch(:ref) == model }

    visible = ActiveModel::Type::Boolean.new.cast(fields.fetch(:visible))
    return form_error(:invalid_visibility) if visible.nil?

    result = ModelProviders::SetModelVisibility.call(
      account: account, provider_id: provider_id, model_ref: model, visible: visible,
      expected_lock_version: expected_lock_version(fields)
    )
    if result.done?
      redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.visibility_updated"), status: :see_other
    else
      load_provider
      load_models
      form_error(result.outcome == :stale ? :stale : :invalid_visibility,
        status: result.outcome == :stale ? :conflict : :unprocessable_entity)
    end
  end
end
