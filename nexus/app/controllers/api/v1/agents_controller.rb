# @auth [PlatformBearer, BrowserSession]
class API::V1::AgentsController < API::V1::Agents::BaseController
  include API::V1::AgentReading

  skip_before_action :load_agent, only: [:index, :show, :create]
  before_action :load_readable_agent, only: :show

  # @oas_include
  # @summary List agents
  # @tags Platform, agents
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AgentsIndex
  def index
    page = keyset_page(readable_agents, columns: { public_id: :uuid })
    render json: { agents: page.records.map { |agent| API::AgentPresenter.basic(agent) },
      pagination: { next_after: page.next_after } }
  end

  # @oas_include
  # @summary Read agents
  # @tags Platform, agents
  # @parameter id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AgentsShow
  def show
    render json: { agent: API::AgentPresenter.full(@agent) }
  end

  # @oas_include
  # @summary Create agents
  # @tags Platform, agents
  # @request_body_ref #/components/requestBodies/ApiV1AgentsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (201) #/components/responses/ApiV1AgentsCreate
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
