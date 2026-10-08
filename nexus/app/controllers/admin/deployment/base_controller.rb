class Admin::Deployment::BaseController < Admin::BaseController
  include DeploymentRequests

  private

    def load_deployment
      result = deployment_client.status
      if result.success?
        @deployment = result.data
      else
        @deployment_error = result.error
      end
      @upgrade_key = SecureRandom.uuid_v7
      result
    end

    def render_deployment_failure(result)
      load_deployment
      @deployment_error = result.error
      render "admin/deployments/show", status: result.status
    end
end
