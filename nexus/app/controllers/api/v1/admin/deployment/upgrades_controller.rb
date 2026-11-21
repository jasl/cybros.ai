# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::Deployment::UpgradesController < API::V1::Admin::Deployment::BaseController
  # @oas_include
  # @summary Read upgrades
  # @tags Platform, upgrades
  # @parameter id(path) [!String] Resource selector.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminDeploymentUpgradesShow
  def show
    deployment_json(deployment_client.receipt(operation_id: params[:id].to_s), resource: :upgrade)
  end

  # @oas_include
  # @summary Create upgrades
  # @tags Platform, upgrades
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (202) #/components/responses/ApiV1AdminDeploymentUpgradesCreate
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
