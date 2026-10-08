class Admin::Deployment::ReleaseChecksController < Admin::Deployment::BaseController
  def create
    result = deployment_client.check(**deployment_check_options)
    respond_to do |format|
      format.json { deployment_json(result, resource: :deployment) }
      format.html do
        if result.success?
          redirect_to admin_deployment_path, status: :see_other
        else
          render_deployment_failure(result)
        end
      end
    end
  end
end
