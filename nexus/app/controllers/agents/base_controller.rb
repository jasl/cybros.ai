# Every command resolves inside the signed-in human's own steward scope:
# another steward's profile is simply not found.
class Agents::BaseController < ApplicationController
  private

    def agent_profile
      @agent_profile ||= Current.user.stewarded_agents.find_by!(
        public_id: params[:agent_public_id] || params[:public_id]
      )
    end

    # The show page's facts — what `show` renders and what a refused
    # command re-renders over (`Agents::HandlesController`), so the page
    # never loses its address beside a field's error.
    def prepare_show
      @agent_profile = agent_profile
      @current_address = TaskExecutor.address_for(@agent_profile)
      @address = @current_address || TaskExecutor.latest_address_for(@agent_profile)
      @credential_readiness = TaskExecutor
        .credential_readiness_for(Array(@current_address))
        .fetch(@current_address&.id, :no_credential)
      @current_lineage = current_lineage_for(@current_address)
    end

    # Pairing history supplies descriptive timestamps only. Address existence
    # and credential usability come from their own canonical projections.
    def current_lineage_for(address)
      return unless address

      @agent_profile.refresh_token_families.live
        .where(
          task_executor: address,
          credential_epoch: address.credential_epoch
        )
        .order_by_recency
        .first
    end
end
