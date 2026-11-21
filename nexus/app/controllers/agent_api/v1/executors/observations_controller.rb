# @auth [ExecutorBearer]
class AgentAPI::V1::Executors::ObservationsController < AgentAPI::V1::Executors::BaseController
  include AgentAPI::V1::OperationScoped

  # @oas_include
  # @summary Create observations
  # @tags Executor, observations
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/AgentApiV1ExecutorsObservationsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ExecutorsObservationsCreate
  def create
    proof = params.permit(:claim_token)
    result = Executors::TaskOperations::Observe.new(access: operation_access(proof[:claim_token]),
      after: operation_position(:after)).call
    render_operation_result(result) { |value| render json: value }
  end
end
