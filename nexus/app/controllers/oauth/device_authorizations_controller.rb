# RFC 8628 initiation. The original connector and Human application login use
# the same claim grammar and downstream binding ceremony.
class OAuth::DeviceAuthorizationsController < OAuth::MachineController
  rate_limit to: 6, within: 1.minute,
    by: -> { request.remote_ip },
    scope: "oauth/device-authorization",
    with: -> { render_rate_limited(retry_after: 60) }

  rescue_from OAuth::InvalidRequest, with: -> { render_oauth_error(:invalid_request) }

  def create
    return render_oauth_error(:invalid_client) unless OAuth::Client.registered?(scalar_field(:client_id))

    attributes = OAuth::ConnectionRequest::CONNECTION_FIELDS.to_h { |field| [field, scalar_field(field)] }.compact
    connection = OAuth::ConnectionRequest.new(attributes)
    unless connection.valid?
      return render_oauth_error(connection.errors[:scope].any? ? :invalid_scope : :invalid_request)
    end

    account = Account.first
    if account.nil?
      if connection.application?
        render json: {
          error: "initialization_required",
          initialization_uri: setup_url(**Rails.application.routes.default_url_options),
        }, status: :conflict
      else
        render_oauth_error(:invalid_request)
      end
      return
    end

    mint = DeviceAuthorizations::Issue.call(
      account: account, **connection.issue_attributes,
      request_ip: request.remote_ip, request_user_agent: request.user_agent
    )
    public_url_options = Rails.application.routes.default_url_options
    render json: {
      device_code: mint.device_code,
      user_code: mint.authorization.formatted_user_code,
      verification_uri: oauth_device_url(**public_url_options),
      verification_uri_complete: oauth_device_url(**public_url_options, user_code: mint.authorization.formatted_user_code),
      expires_in: DeviceAuthorization::TTL.to_i,
      interval: DeviceAuthorization.default_interval,
    }
  end
end
