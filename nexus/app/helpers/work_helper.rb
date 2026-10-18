module WorkHelper
  def work_status_label(status)
    t("work_console.statuses.#{status}")
  end

  def work_run_title(run)
    title = run.turn.conversation.title if !run.standalone?
    title.presence || t("work_console.run_label", id: run.public_id.first(8))
  end

  def work_list_parameters
    params.permit(:workspace_public_id, :status, :attention, :from, :to, :answering_user_public_id,
      :agent_public_id, :executor_public_id, :kind, :view, :order, :limit).to_h
  end

  def work_reset_filters_path
    return request.path unless @selected_workspace

    "#{request.path}?#{ { workspace_public_id: @selected_workspace.public_id }.to_query}"
  end
end
