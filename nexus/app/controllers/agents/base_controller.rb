# Every command resolves inside the signed-in human's own steward scope:
# another steward's profile is simply not found.
class Agents::BaseController < ApplicationController
  private

    def agent
      @agent ||= Current.user.stewarded_agents.includes(:derived_from, :steward).find_by!(
        public_id: params[:agent_public_id] || params[:public_id]
      )
    end

    def independent_agent
      row = agent
      raise ActiveRecord::RecordNotFound if row.named_agent?

      row
    end

    # The show page's facts — what `show` renders and what a refused
    # command re-renders over (`Agents::HandlesController`), so the page
    # never loses its address beside a field's error.
    def prepare_show
      @agent = agent
      @current_address = Executor.address_for(@agent)
      @address = @current_address || Executor.latest_address_for(@agent)
      @credential_readiness = Executor
        .credential_readiness_for(Array(@current_address))
        .fetch(@current_address&.id, :no_credential)
      @current_lineage = current_lineage_for(@current_address)
      @static_executor_keys = @current_address&.api_keys&.exists? || false
      @declaration = AgentAPI::ProfilePresenter.configuration(@agent)
      @recent_work = WorkReports::RecentWork.call(user: Current.user, agent: @agent)
      @application_connection = API::AgentPresenter.full(@agent).fetch(:application_connection) if @agent.named_agent?
    end

    # Pairing history supplies descriptive timestamps only. Address existence
    # and credential usability come from their own canonical projections.
    def current_lineage_for(address)
      return unless address

      @agent.refresh_token_families.live
        .where(
          executor: address,
          credential_epoch: address.credential_epoch
        )
        .order_by_recency
        .first
    end
end
