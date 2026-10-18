class Runs::Tasks::SealedRequestsController < Runs::BaseController
  def show
    @task = @run.tasks.find_by!(node_key: params.fetch(:task_id))
    invocation = @task.selected_model_invocation
    return render_error(:request_not_sealed, t("runs_console.request_not_sealed"), status: :not_found) unless invocation

    @sealed_request = AgentAPI::SealedRequestPresenter.call(invocation).fetch(:request)
  end
end
