module Agents::APIKeyManagement
  extend ActiveSupport::Concern

  included do
    before_action :load_independent_agent
    helper_method :keys_path, :new_key_path, :key_revocation_path, :key_kind
    rate_limit to: 10, within: 3.minutes, by: -> { Current.user.public_id },
      scope: "agent-api-key-issuance", only: :create,
      with: -> { redirect_to keys_path, alert: t("agents.api_keys.rate_limited") }
  end

  def index
    @keys_pagy, keys = pagy(:offset,
      api_keys.includes(:executor, user: [:identity, :steward]).order_by_recency, limit: 10)
    @keys = keys.map { |key| [key, API::APIKeyPresenter.basic(key)] }
    render "agents/api_keys/index"
  end

  def new
    @token = AccessToken.new
    render "agents/api_keys/new"
  end

  def create
    fields = params.expect(api_key: [:name, :note])
    name = fields[:name].to_s
    note = fields[:note].to_s.presence
    result = issue_key(name: name, note: note)
    case result.outcome
    when :issued
      no_store
      @token = result.token
      @secret = result.secret
      render "agents/api_keys/reveal", status: :created
    when :invalid, :not_issuable
      @token = result.token || AccessToken.new(name: name, note: note)
      @form_error = t("agents.api_keys.not_issuable") if result.outcome == :not_issuable
      render "agents/api_keys/new", status: :unprocessable_entity
    else
      raise ArgumentError, "unsupported API key issuance outcome: #{result.outcome.inspect}"
    end
  end

  private

    def load_independent_agent
      @agent = independent_agent
    end
end
