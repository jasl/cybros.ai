class AgentsController < Agents::BaseController
  PAGE_SIZE = 10

  def index
    @agents_pagy, @agents = pagy(
      :offset,
      # The declarer rides each named definition's row.
      Current.user.stewarded_agents.includes(:derived_from).order_by_display_name,
      limit: PAGE_SIZE
    )
    addresses = TaskExecutor.live.where(
      executor_kind: :agent_application,
      agent_profile_id: @agents.map(&:id)
    ).to_a
    @agent_addresses = addresses.index_by(&:agent_profile_id)
    @agent_credential_readiness = TaskExecutor.credential_readiness_for(addresses)
  end

  def show
    prepare_show
  end
end
