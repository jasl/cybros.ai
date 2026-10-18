class DashboardController < Work::BaseController
  def show
    @as_of = Time.current
    @from = @as_of - 7.days
    @agent_count = acting_user.stewarded_agents.count
    @workspace_count = browsable_workspaces.count
    @needs_model_provider = acting_user.admin? && !models_ready?
    conversations = Conversation.visible_to(acting_user)
    @usage = ModelUsageRollups::ConversationSummary.call(account: current_account,
      conversations: conversations, from: @from, to: @as_of)
    @recent_work = WorkReports::RecentWork.call(user: acting_user)
    @attention_tasks = Run::AvailableActions.attention_tasks(runs: Run.writable_by(acting_user))
      .includes(run: [:workspace, { turn: :conversation }]).order(updated_at: :desc, id: :desc).limit(5).to_a
  end

  private

    def models_ready?
      catalog = ModelSelection::Resolver.effective_catalog(Current.account, ModelCatalog.current)
      AgentAPI::ModelPresenter.index(account: Current.account, catalog: catalog).any? do |model|
        model.fetch(:workload) == "text_generation" && model.fetch(:available)
      end
    end
end
