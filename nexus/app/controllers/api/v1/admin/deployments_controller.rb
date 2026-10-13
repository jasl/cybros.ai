class API::V1::Admin::DeploymentsController < API::V1::Admin::Deployment::BaseController
  def show
    deployment_json(deployment_client.status, resource: :deployment)
  end
end
