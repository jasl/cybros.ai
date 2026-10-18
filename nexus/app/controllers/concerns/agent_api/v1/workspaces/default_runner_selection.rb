module AgentAPI::V1::Workspaces::DefaultRunnerSelection
  extend ActiveSupport::Concern

  private

    def select_default_runner(host)
      fields = params.expect(default_runner: [:executor_public_id])
      raise APIErrors::ParameterInvalid, :executor_public_id unless fields.key?(:executor_public_id)
      result = ::Executors::DefaultRunner.call(::Executors::DefaultRunner::Command.new(
        host: host, executor_public_id: fields[:executor_public_id], acting_user: acting_user
      ))
      case result.outcome
      when :accepted then render_selected_host(result.value)
      when :runner_not_found
        render_error(:runner_not_found, "No Runner is known by that id", status: :not_found)
      when :runner_not_eligible
        render_error(:runner_not_eligible, result.detail, status: :conflict)
      else render_refusal(result.outcome)
      end
    end
end
