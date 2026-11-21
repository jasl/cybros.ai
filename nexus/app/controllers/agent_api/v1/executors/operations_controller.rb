# @auth [ExecutorBearer]
class AgentAPI::V1::Executors::OperationsController < AgentAPI::V1::Executors::BaseController
  include AgentAPI::V1::OperationScoped

  # @oas_include
  # @parameter_ref #/components/parameters/ClaimToken
  # @parameter after(query) [Integer] Last observed operation position.
  # @parameter limit(query) [Integer] Maximum trace items.
  # @summary List operations
  # @tags Executor, operations
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ExecutorsOperationsIndex
  def index
    token = request.headers["Claim-Token"]
    raise ActionController::ParameterMissing.new("Claim-Token") if token.blank?

    result = operation_access(token).read do |node|
      Executors::Outcome.accepted(Executors::TaskOperations::Trace.snapshot(node,
        after: operation_position(:after, default: 0),
        limit: limit_param(default: Executors::TaskOperations::Trace::PAGE_SIZE,
          max: Executors::TaskOperations::Trace::MAX_PAGE_SIZE)))
    end
    render_operation_result(result) { |value| render json: { operations: value } }
  end

  # @oas_include
  # @summary Create operations
  # @tags Executor, operations
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/AgentApiV1ExecutorsOperationsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ExecutorsOperationsCreate
  # @response_ref (201) #/components/responses/AgentApiV1ExecutorsOperationsCreate
  def create
    fields = params.expect(operation: [:key])
    proof = params.permit(:claim_token)
    # executor-operations.md: operation.request is the explicit opaque
    # JSON exception; its semantic validation belongs to the task owner.
    request_value = request.request_parameters.fetch("operation").fetch("request")
    result = Executors::TaskOperations::Submit.new(access: operation_access(proof[:claim_token]),
      key: fields.fetch(:key), request: request_value).call
    render_operation_result(result) do |value|
      render json: { operation: value.fetch("operation") }, status: value.fetch("created") ? :created : :ok
    end
  end
end
