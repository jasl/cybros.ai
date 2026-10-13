class API::V1::Admin::Deployment::Upgrades::LogsController < API::V1::Admin::Deployment::Upgrades::BaseController
  def show
    result = deployment_client.log(operation_id: params[:upgrade_id].to_s, cursor: deployment_cursor)
    deployment_json(result, resource: :log)
  end
end
