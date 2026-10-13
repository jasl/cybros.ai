class API::V1::Admin::Deployment::UpgradesController < API::V1::Admin::Deployment::BaseController
  def show
    deployment_json(deployment_client.receipt(operation_id: params[:id].to_s), resource: :upgrade)
  end

  def create
    result = deployment_client.upgrade(
      idempotency_key: request.headers["Idempotency-Key"].to_s,
      actor_public_id: Current.user.public_id, candidate: deployment_candidate, backup: deployment_backup
    )
    if result.success?
      response.set_header("Location", api_v1_admin_deployment_upgrade_url(result.data.id))
    end
    deployment_json(result, resource: :upgrade)
  end
end
