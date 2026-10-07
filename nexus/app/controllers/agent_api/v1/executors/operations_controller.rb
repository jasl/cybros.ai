class AgentAPI::V1::Executors::OperationsController < AgentAPI::V1::Executors::BaseController
  include AgentAPI::V1::OperationScoped

  def index
    token = request.headers["Claim-Token"]
    raise ActionController::ParameterMissing.new("Claim-Token") if token.blank?

    result = operation_access(token).read do |node|
      Executors::Outcome.accepted(Executors::TaskOperations::Trace.snapshot(node,
        after: operation_position(:after, default: 0), limit: operation_position(:limit, default: 100)))
    end
    render_operation_result(result) { |value| render json: { operations: value } }
  end

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
