# Cookie consent for Authorization Code + PKCE. Only a registered callback can
# receive a response; the code carries no authority without its verifier.
class OAuth::AuthorizationsController < OAuth::BrowserController
  include OAuthParameters
  layout "public"

  skip_before_action :ensure_verified_grant_context, only: %i[show create]
  prepend_before_action :validate_authorization_request
  prepend_before_action :protect_capability_page_response
  before_action :load_runner_precondition, only: :show
  rate_limit to: 12, within: 1.minute, only: :create,
    by: -> { Current.user.public_id },
    with: -> { head :too_many_requests }

  rescue_from OAuth::InvalidRequest, with: -> { render plain: "Invalid authorization request", status: :bad_request }

  def show
    # A native same-origin consent POST needs its browser Origin for Rails
    # CSRF verification. Cross-origin navigation still receives no Referer.
    response.headers["Referrer-Policy"] = "same-origin"
  end

  def create
    if scalar_field(:decision) == "deny"
      redirect_response(error: "access_denied")
    else
      mint = DeviceAuthorizations::Issue.call(
        account: Current.account, **@authorization_request.issue_attributes,
        request_ip: request.remote_ip, request_user_agent: request.user_agent
      )
      result = DeviceAuthorizations::Connect.call(
        authorization: mint.authorization, connector: Current.user,
        expected_live_runner: scalar_field(:expected_live_runner),
        account_wide: scalar_field(:account_wide) == "1"
      )
      if result.outcome == :connected
        redirect_response(code: mint.device_code)
      else
        mint.authorization.record_cancellation if mint.authorization.pending?
        redirect_response(error: "access_denied", error_description: result.outcome.to_s)
      end
    end
  end

  private

    # Only this validated OAuth request survives first boot. The setup secret
    # remains a separate installer capability and never enters the request.
    def require_initialization
      redirect_to setup_path(return_to: resumable_request_url) if Account.none?
    end

    def validate_authorization_request
      attributes = OAuth::ConnectionRequest::FIELDS.to_h { |field| [field, scalar_field(field)] }.compact
      @authorization_request = OAuth::ConnectionRequest.new(attributes.merge(flow: :authorization_code))
      unless @authorization_request.valid?
        render plain: "Invalid authorization request", status: :bad_request
      end
    end

    def load_runner_precondition
      if @authorization_request.agent_identifier.nil?
        runner = TaskExecutor.runner_for(
          account_id: Current.account.id, manager_id: Current.user.id,
          registration_identifier: @authorization_request.registration_identifier
        )
        @expected_live_runner = DeviceAuthorizations::Connect.live_runner_precondition(runner)
        @existing_runner = runner
      end
    end

    def redirect_response(**response_fields)
      uri = URI.parse(@authorization_request.redirect_uri)
      fields = URI.decode_www_form(uri.query.to_s)
      fields.concat(response_fields.merge(state: @authorization_request.state).to_a)
      uri.query = URI.encode_www_form(fields)
      redirect_to uri.to_s, allow_other_host: true, status: :see_other
    end
end
