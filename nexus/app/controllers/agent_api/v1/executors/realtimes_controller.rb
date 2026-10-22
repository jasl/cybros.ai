class AgentAPI::V1::Executors::RealtimesController < AgentAPI::V1::Executors::BaseController
  include AgentAPI::RealtimeSignaling

  def show
    run = find_addressable_loop
    node = realtime_task(run)
    return unless node

    render json: { realtime: Executors::Realtime.new(node, credential: current_credential).projection }
  end

  def update
    fields = signal_parameters
    previous = params[:previous_connection_id]&.to_s
    if previous && !Tasks::ToolTask::RealtimeSignal::CONNECTION_ID.match?(previous)
      raise APIErrors::ParameterInvalid, :previous_connection_id
    end
    run = find_addressable_loop
    run.with_lock do
      node = realtime_task(run, lock: true)
      return unless node

      realtime = Executors::Realtime.new(node, credential: current_credential)
      outcome = realtime.offer(**fields, token: request.headers["Claim-Token"], previous_connection_id: previous)
      render_signal_outcome(outcome, realtime)
    end
  end

  private

    def realtime_task(run, lock: false)
      raise ActiveRecord::RecordNotFound if run.tombstoned?
      token = request.headers["Claim-Token"].presence
      raise ActionController::ParameterMissing.new("Claim-Token") unless token

      scope = run.tasks.where(type: "Tasks::ToolTask")
      node = (lock ? scope.lock : scope).find_by!(node_key: params.fetch(:task_key))
      return node if node.addressed_role == "runner" && node.claimed_by?(current_executor, token: token)

      render_error(:not_claimant, "Refused: not_claimant", status: :conflict)
      nil
    end
end
