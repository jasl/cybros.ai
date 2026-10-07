class API::V1::Admin::ModelProviders::ModelDiscoveriesController < API::V1::Admin::ModelProviders::BaseController
  def create
    fields = params.expect(command: [:expected_lock_version])
    result = ModelProviders::DiscoverModels.call(
      account: account, provider_id: provider_id, expected_lock_version: expected_version(fields)
    )
    return render json: { models: result.models } if result.success?

    if result.outcome == :stale
      render_error(:stale_object, "The provider changed since you read it", status: :conflict)
    else
      render_error(:validation_failed, "Model discovery failed: #{result.outcome}", status: :unprocessable_entity)
    end
  end
end
