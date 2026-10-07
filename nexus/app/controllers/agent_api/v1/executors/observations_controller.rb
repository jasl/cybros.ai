class AgentAPI::V1::Executors::ObservationsController < AgentAPI::V1::Executors::BaseController
  include AgentAPI::V1::OperationScoped

  def create
    proof = params.permit(:claim_token)
    result = Executors::TaskOperations::Observe.new(access: operation_access(proof[:claim_token]),
      after: operation_position(:after)).call
    render_operation_result(result) { |value| render json: value }
  end
end
