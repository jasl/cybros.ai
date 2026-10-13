class Admin::DeploymentsController < Admin::Deployment::BaseController
  def show
    result = load_deployment
    @upgrade = @deployment&.active_operation || @deployment&.last_operation
    render :show, status: result.status
  end
end
