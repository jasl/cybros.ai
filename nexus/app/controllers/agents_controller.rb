class AgentsController < Agents::BaseController
  PAGE_SIZE = 10
  SEARCH_QUERY_MAX_LENGTH = 100

  def index
    @query = params.permit(:query).fetch(:query, "").to_s.strip[0, SEARCH_QUERY_MAX_LENGTH]
    @status = params[:status].to_s.presence_in(%w[active removed])
    agents = Current.user.stewarded_agents.matching_name_or_handle(@query)
    agents = agents.where(status: @status) if @status
    @agents_pagy, @agents = pagy(
      :offset,
      # The declarer rides each named definition's row.
      agents.includes(:steward, derived_from: :steward).order_by_display_name,
      limit: PAGE_SIZE
    )
    application_owners = @agents.to_h do |row|
      owner = row.application_owner if row.execution_principal_eligible?
      [row.id, owner&.active? ? owner : nil]
    end
    addresses = Executor.live.where(
      executor_kind: :agent_application,
      agent_id: (@agents.map(&:id) + application_owners.values.compact.map(&:id)).uniq
    ).to_a
    @agent_addresses = addresses.index_by(&:agent_id)
    @agent_application_addresses = application_owners.transform_values { |owner| @agent_addresses[owner&.id] }
    @agent_credential_readiness = Executor.credential_readiness_for(addresses)
  end

  def show
    prepare_show
  end

  def new
    @agent = Current.user.build_agent(display_name: "")
  end

  def create
    fields = params.expect(agent: [:display_name])
    @agent = Current.user.build_agent(display_name: fields[:display_name].to_s)
    if @agent.save
      redirect_to agent_path(@agent), notice: t("agents.created")
    else
      render :new, status: :unprocessable_entity
    end
  end
end
