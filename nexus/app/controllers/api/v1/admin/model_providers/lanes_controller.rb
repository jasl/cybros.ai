# PUT /api/v1/admin/model_providers/{id}/lane. Enabling creates the policy row,
# so `expected_lock_version` is null for an untouched lane; a stale version is
# a conflict, never a last-writer-wins overwrite.
class API::V1::Admin::ModelProviders::LanesController < API::V1::Admin::ModelProviders::BaseController
  LOCK_VERSION_RANGE = (0..2_147_483_647)

  def update
    fields = params.expect(command: [:enabled, :expected_lock_version])
    enabled = fields[:enabled]
    return render_error(:parameter_invalid, "enabled must be true or false",
      status: :bad_request) unless [true, false].include?(enabled)

    version = fields[:expected_lock_version]
    version = bounded_integer(version, :expected_lock_version, range: LOCK_VERSION_RANGE) unless version.nil?

    command = enabled ? ModelProviders::EnableLane : ModelProviders::DisableLane
    result = command.call(
      account: account, provider_id: provider_id,
      expected_lock_version: version
    )
    return render_lane if result.done?

    case result.outcome
    when :not_found
      render_not_found
    when :stale
      render_error(:stale_object, "The lane changed since you read it", status: :conflict)
    else
      render_error(:parameter_invalid, "The lane could not be changed",
        status: :bad_request)
    end
  end
end
