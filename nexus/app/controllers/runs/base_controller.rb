class Runs::BaseController < Work::BaseController
  include AgentAPI::KeysetPagination
  before_action :set_run
  before_action :require_execution_details

  private

    def set_run
      @run = find_visible_run(:run_id)
      @actions = Run::AvailableActions.new(run: @run, user: acting_user)
    end

    def require_execution_details
      return unless @run.details_pruned_at

      render_error(:execution_details_pruned, t("runs_console.details_pruned"), status: :gone)
    end

    def lifecycle(service, **command)
      result = service.call(service::Command.new(run: @run, acting_user: acting_user, **command))
      return command_refused(result.outcome) unless result.accepted?

      redirect_to run_path(@run, return_to: work_return_path(workspace_runs_path(@run.workspace))), status: :see_other,
        notice: t("runs_console.command_accepted")
    end

    def adjudicate(service, notice: "runs_console.command_accepted", **command)
      result = service.call(service::Command.new(run: @run, task_key: params.fetch(:task_id),
        acting_user: acting_user, **command))
      return command_refused(result.outcome) unless result.accepted?

      redirect_to run_task_path(@run, params.fetch(:task_id), return_to: work_return_path(run_tasks_path(@run))),
        status: :see_other, notice: t(notice)
    end

    def command_refused(outcome)
      return render_not_found if %i[not_found task_not_found].include?(outcome)

      status = outcome == :not_authorized ? :forbidden : :conflict
      reason = t("runs_console.refusal_reasons.#{outcome}", default: outcome.to_s)
      render_error(outcome, t("runs_console.command_refused", reason: reason), status: status)
    end

    def task_scope
      @run.tasks.includes(:sources, :addressed_executor, :target_executor, :mcp_connection, :approved_by_user)
    end
end
