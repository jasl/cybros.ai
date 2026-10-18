module API::V1::Agents::APIKeyActions
  extend ActiveSupport::Concern

  included do
    rate_limit to: 10, within: 3.minutes, by: -> { Current.user.public_id },
      scope: "agent-api-key-issuance", only: :create,
      with: -> { render_rate_limited(retry_after: 3.minutes) }
  end

  def index
    page = keyset_page(api_keys.includes(:executor, user: [:identity, :steward]), columns: { public_id: :uuid })
    render json: { api_keys: page.records.map { |key| API::APIKeyPresenter.basic(key) },
      pagination: { next_after: page.next_after } }
  end

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
