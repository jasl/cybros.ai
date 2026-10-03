class API::V1::Admin::ModelProviders::ModelVisibilitiesController < API::V1::Admin::ModelProviders::BaseController
  LOCK_VERSION_RANGE = (0..2_147_483_647)

  def update
    fields = params.expect(command: [:model, :visible, :expected_lock_version])
    visible = fields[:visible]
    return render_error(:parameter_invalid, "visible must be true or false",
      status: :bad_request) unless [true, false].include?(visible)

    model = fields[:model].to_s
    catalog = ModelSelection::Resolver.effective_provider_catalog(account, snapshot, provider_id)
    unless ModelProviderPolicy.provider_lane_ref?(provider_id, model) && catalog.models.key?(model)
      return render_not_found
    end

    version = fields[:expected_lock_version]
    version = bounded_integer(version, :expected_lock_version, range: LOCK_VERSION_RANGE) unless version.nil?
    result = ModelProviders::SetModelVisibility.call(
      account: account, provider_id: provider_id, model_ref: model,
      visible: visible, expected_lock_version: version
    )
    return render_lane if result.done?

    case result.outcome
    when :not_found
      render_not_found
    when :stale
      render_error(:stale_object, "The lane changed since you read it", status: :conflict)
    else
      render_error(:validation_failed, "The model visibility could not be changed", status: :unprocessable_entity)
    end
  end
end
