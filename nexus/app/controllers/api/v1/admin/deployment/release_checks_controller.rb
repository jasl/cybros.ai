class API::V1::Admin::Deployment::ReleaseChecksController < API::V1::Admin::Deployment::BaseController
  def create
    deployment_json(deployment_client.check(**deployment_check_options), resource: :deployment)
  end
end
