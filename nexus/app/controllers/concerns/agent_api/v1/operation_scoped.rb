module AgentAPI::V1::OperationScoped
  extend ActiveSupport::Concern

  private

    def operation_access(token)
      Executors::TaskOperations::Access.new(agent_run: find_addressable_loop,
        task_key: params.fetch(:task_key), executor: current_executor, claim_token: token)
    end

    def render_operation_result(result)
      if result.accepted?
        yield result.value
      else
        status = case result.outcome
        when :not_found then :not_found
        when :invalid_operation_key, :invalid_operation, :operation_too_large then :unprocessable_entity
        else :conflict
        end
        render_error(result.outcome, result.detail || "Refused: #{result.outcome}", status: status)
      end
    end

    def operation_position(name, default: nil)
      value = params[name]
      return default if value.nil? && !default.nil?

      # executor-operations.md: positions and page sizes are bounded JSON
      # integers; they coordinate observation publication, not program data.
      bounded_integer(value, name, range: 0..2_147_483_647)
    end
end
