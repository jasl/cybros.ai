class AgentAPI::V1::Workspaces::Runs::Tasks::RealtimesController < AgentAPI::V1::Workspaces::Runs::BaseController
  include AgentAPI::RealtimeSignaling

  def show
    realtime = realtime_for(find_listable_loop(@workspace))
    return unless realtime

    render json: { realtime: realtime.projection }
  end

  def update
    fields = signal_parameters
    run = find_listable_loop(@workspace)
    run.with_lock do
      realtime = realtime_for(run, lock: true)
      return unless realtime

      render_signal_outcome(realtime.answer(**fields), realtime)
    end
  end

  private

    def realtime_for(run, lock: false)
      scope = run.tasks.where(type: "Tasks::ToolTask")
      node = (lock ? scope.lock : scope).find_by!(node_key: params.fetch(:task_key))
      realtime = Executors::Realtime.new(node, credential: current_credential)
      return realtime if realtime.member?

      render_error(:not_authorized, "Refused: not_authorized", status: :forbidden)
      nil
    end
end
