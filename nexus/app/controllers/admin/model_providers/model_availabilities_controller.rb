class Admin::ModelProviders::ModelAvailabilitiesController < Admin::ModelProviders::BaseController
  before_action :load_models

  def update
    fields = params.expect(model_availability: [:model, :available, :expected_lock_version])
    model = fields.fetch(:model).to_s
    raise ActiveRecord::RecordNotFound unless @models.any? { |row| row.fetch(:ref) == model }

    available = ActiveModel::Type::Boolean.new.cast(fields.fetch(:available))
    raise ActionController::BadRequest, "available is required" if available.nil?

    result = ModelProviders::SetModelAvailability.call(
      account: account, provider_id: provider_id, model_ref: model, available: available,
      expected_lock_version: expected_lock_version(fields)
    )
    if result.done?
      redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.availability_updated"), status: :see_other
    else
      flash.now[:alert] = t("admin.model_providers.#{result.outcome == :stale ? :stale : :invalid_availability}")
      load_provider
      load_models
      render "admin/model_providers/model_visibilities/show", status: result.outcome == :stale ? :conflict : :unprocessable_entity
    end
  end
end
