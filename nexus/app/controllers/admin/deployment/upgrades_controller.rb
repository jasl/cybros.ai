class Admin::Deployment::UpgradesController < Admin::Deployment::BaseController
  def show
    result = deployment_client.receipt(operation_id: params[:id].to_s)
    if result.success?
      load_deployment
      @upgrade = result.data
      render "admin/deployments/show"
    else
      render_deployment_failure(result)
    end
  end

  def create
    result = deployment_client.upgrade(
      idempotency_key: params.permit(:idempotency_key)[:idempotency_key].to_s,
      actor_public_id: Current.user.public_id, candidate: deployment_candidate, backup: deployment_backup
    )
    if result.success?
      response.set_header("Location", admin_deployment_upgrade_url(result.data.id))
    end
    respond_to do |format|
      format.json { deployment_json(result, resource: :upgrade) }
      format.html do
        if result.success?
          redirect_to admin_deployment_upgrade_path(result.data.id), status: :see_other
        else
          render_deployment_failure(result)
        end
      end
    end
  end
end
