class API::V1::AgentsController < API::V1::Agents::BaseController
  include API::V1::AgentReading

  skip_before_action :load_agent, only: [:index, :show, :create]
  before_action :load_readable_agent, only: :show

  def index
    page = keyset_page(readable_agents, columns: { public_id: :uuid })
    render json: { agents: page.records.map { |agent| API::AgentPresenter.basic(agent) },
      pagination: { next_after: page.next_after } }
  end

  def show
    render json: { agent: API::AgentPresenter.full(@agent) }
  end

  def create
    fields = params.expect(agent: [:display_name])
    @agent = Current.user.create_agent(display_name: fields[:display_name].to_s)
    if @agent.persisted?
      render json: { agent: API::AgentPresenter.basic(@agent) }, status: :created
    else
      render_error(:validation_failed, @agent.errors.full_messages.to_sentence, status: :unprocessable_entity)
    end
  end
end
