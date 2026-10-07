class Admin::ModelProviders::LanesController < Admin::ModelProviders::BaseController
  def show
  end

  def update
    fields = params.expect(lane: [:enabled, :expected_lock_version])
    enabled = ActiveModel::Type::Boolean.new.cast(fields.fetch(:enabled))
    return form_error(:invalid_lane) if enabled.nil?

    command = enabled ? ModelProviders::EnableLane : ModelProviders::DisableLane
    result = command.call(account: account, provider_id: provider_id, expected_lock_version: expected_lock_version(fields))
    if result.done?
      redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.lane_updated"), status: :see_other
    else
      load_provider
      form_error(result.outcome == :stale ? :stale : :invalid_lane,
        status: result.outcome == :stale ? :conflict : :unprocessable_entity)
    end
  end
end
