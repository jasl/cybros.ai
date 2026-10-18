class Runs::Tasks::ResolutionsController < Runs::BaseController
  def create
    return command_refused(:not_authorized) unless @run.writable_by?(acting_user)

    node = @run.tasks.find_by!(node_key: params.fetch(:task_id))
    return command_refused(:not_adjudicable) unless @actions.answer?(node)

    answer = params.require(:answer).to_s
    result = Runs::Parks::Settle.call(node: node, content: [{ "type" => "text", "text" => answer }],
      creator: acting_user,
      resolved_by: { "kind" => acting_user.kind, "public_id" => acting_user.public_id, "handle" => acting_user.handle })
    return command_refused(result.outcome) unless result.settled?

    redirect_to run_task_path(@run, node.node_key, return_to: work_return_path(run_tasks_path(@run))),
      status: :see_other, notice: t("runs_console.command_accepted")
  end
end
