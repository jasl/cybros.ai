class DashboardController < ApplicationController
  def show
    @needs_model_provider = Current.user.admin? && !models_ready?
    @needs_agent = !agent_connected?
  end

  private

    def models_ready?
      catalog = ModelSelection::Resolver.effective_catalog(Current.account, ModelCatalog.current)
      AgentAPI::ModelPresenter.index(account: Current.account, catalog: catalog).any? do |model|
        model.fetch(:workload) == "text_generation" && model.fetch(:available)
      end
    end

    def agent_connected?
      addresses = TaskExecutor.live.where(
        executor_kind: :agent_application, agent_profile: Current.user.stewarded_agents.active
      ).includes(agent_profile: :steward)
      addresses.find_in_batches(batch_size: 100).any? do |batch|
        readiness = TaskExecutor.credential_readiness_for(batch)
        batch.any? { |address| address.eligible_for?(Current.user, readiness: readiness) }
      end
    end
end
