# GET /agent_api/v1/executor — the executor plane's self-description: the
# process proves its transport credential and learns which delivery address it
# is without a member-plane call. The credential names the address. The member
# plane's discovery of executors OTHERS may address is the plural
# `AgentAPI::V1::ExecutorsController`.
# @auth [ExecutorBearer]
class AgentAPI::V1::Executors::DescriptionsController < AgentAPI::V1::Executors::BaseController
  # @oas_include
  # @summary Read descriptions
  # @tags Executor, descriptions
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ExecutorsDescriptionsShow
  def show
    render json: AgentAPI::ExecutorPresenter.description(
      current_executor, measured_at: Time.current, live_server_ids: NexusServer.live_ids
    )
  end
end
