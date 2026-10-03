class API::V1::Admin::ModelProviders::ModelDiscoveriesController < API::V1::Admin::ModelProviders::BaseController
  def create
    result = ModelProviders::DiscoverModels.call(account: account, provider_id: provider_id)
    return render json: { models: result.models } if result.success?

    render_error(:validation_failed, "Model discovery failed: #{result.outcome}", status: :unprocessable_entity)
  end
end
