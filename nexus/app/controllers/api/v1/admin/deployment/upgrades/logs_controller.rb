# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::Deployment::Upgrades::LogsController < API::V1::Admin::Deployment::Upgrades::BaseController
  # @oas_include
  # @summary Read logs
  # @tags Platform, logs
  # @parameter upgrade_id(path) [!String] Resource selector.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminDeploymentUpgradesLogsShow
  def show
    result = deployment_client.log(operation_id: params[:upgrade_id].to_s, cursor: deployment_cursor)
    deployment_json(result, resource: :log)
  end
end
