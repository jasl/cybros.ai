class Admin::ModelProviders::ModelDiscoveriesController < Admin::ModelProviders::BaseController
  def show
  end

  def create
    @discovery = ModelProviders::DiscoverModels.call(account: account, provider_id: provider_id)
    render :show, status: @discovery.success? ? :ok : :unprocessable_entity
  end
end
