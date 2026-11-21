# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::Deployment::ReleaseChecksController < API::V1::Admin::Deployment::BaseController
  # @oas_include
  # @summary Create release checks
  # @tags Platform, release checks
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminDeploymentReleaseChecksCreate
  def create
    deployment_json(deployment_client.check(**deployment_check_options), resource: :deployment)
  end
end
