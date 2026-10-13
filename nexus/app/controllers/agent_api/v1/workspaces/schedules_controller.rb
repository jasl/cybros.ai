# The workspace's scheduled jobs across its conversations: the overview a
# person reads before opening a job's own conversation. Rows reach the
# caller through the one conversation funnel the nested list uses, so a
# conversation the caller cannot read contributes nothing.
class AgentAPI::V1::Workspaces::SchedulesController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def index
    scope = Schedule.where(conversation_id: Conversation.visible_to(acting_user, workspace: @workspace).select(:id))
      .includes(:conversation, :creating_user, :answering_user)
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: { schedules: AgentAPI::SchedulePresenter.many(page.records, by: acting_user, workspace: @workspace),
      pagination: { next_after: page.next_after } }
  end
end
