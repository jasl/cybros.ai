module API::V1::Agents::APIKeyActions
  extend ActiveSupport::Concern

  included do
    rate_limit to: 10, within: 3.minutes, by: -> { Current.user.public_id },
      scope: "agent-api-key-issuance", only: :create,
      with: -> { render_rate_limited(retry_after: 3.minutes) }
  end

  # @oas_include
  # @summary List api keys
  # @tags Platform, api keys
  # @parameter agent_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter after(query) [String] Opaque continuation cursor.
  # @parameter limit(query) [Integer] Page size; the resource reference specifies its bound.
  # @parameter order(query) [String] Ordering direction.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ConcernsApiV1AgentsApiKeyActionsRbIndex
  def index
    page = keyset_page(api_keys.includes(:executor, user: [:identity, :steward]), columns: { public_id: :uuid })
    render json: { api_keys: page.records.map { |key| API::APIKeyPresenter.basic(key) },
      pagination: { next_after: page.next_after } }
  end

  # @oas_include
  # @summary Create api keys
  # @tags Platform, api keys
  # @parameter agent_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/ConcernsApiV1AgentsApiKeyActionsRbCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (201) #/components/responses/ConcernsApiV1AgentsApiKeyActionsRbCreate
  def create
    fields = params.expect(api_key: [:name, :note])
    result = issue_key(name: fields[:name].to_s, note: fields[:note].to_s.presence)
    case result.outcome
    when :issued
      response.headers["Cache-Control"] = "no-store"
      render json: { api_key: API::APIKeyPresenter.basic(result.token), secret: result.secret }, status: :created
    when :invalid
      render_error(:validation_failed, result.token.errors.full_messages.to_sentence, status: :unprocessable_entity)
    when :not_issuable
      render_refusal(:not_issuable)
    else
      raise ArgumentError, "unsupported API key issuance outcome: #{result.outcome.inspect}"
    end
  end
end
