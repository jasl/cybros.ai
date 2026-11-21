# POST /oauth/device_authorization/cancellation — a first-party extension. The
# row-lock winner against Consume decides whether the caller may kill its poller.
class OAuth::DeviceAuthorizationCancellationsController < OAuth::MachineController
  rate_limit to: 12, within: 1.minute,
    by: -> { request.remote_ip },
    scope: "oauth/device-authorization-cancellation",
    with: -> { render_rate_limited(retry_after: 5) }

  rescue_from OAuth::InvalidRequest, with: -> { render_oauth_error(:invalid_request) }

  # @oas_include
  # @summary Create device authorization cancellations
  # @tags OAuth, device authorization cancellations
  # @no_auth
  # @request_body_ref #/components/requestBodies/OauthDeviceAuthorizationCancellationsCreate
  # @response_ref (200) #/components/responses/OauthDeviceAuthorizationCancellationsCreate
  # @response_ref (400) #/components/responses/OAuthError
  # @response_ref (409) #/components/responses/OAuthError
  # @response_ref (415) #/components/responses/OAuthError
  # @response_ref (429) #/components/responses/OAuthError
  # @response_ref (500) #/components/responses/ServerError
  def create
    return render_oauth_error(:invalid_client) unless OAuth::Client.registered?(scalar_field(:client_id))
    # Keep the first-party extension tolerant of the same OAuth-library
    # compatibility parameter as the standard machine endpoints.
    scalar_field(:scope)

    raw = scalar_field(:device_code)
    return render_oauth_error(:invalid_request) if raw.nil?

    authorization = DeviceAuthorization.find_by_device_code(raw)
    unless authorization&.device_code? && authorization.client_id == scalar_field(:client_id)
      return render_oauth_error(:invalid_grant)
    end

    result = DeviceAuthorizations::MachineCancel.call(authorization: authorization)
    case result.outcome
    when :canceled then head :ok
    when :consumed then render_oauth_error(:too_late, status: :conflict)
    else
      raise ArgumentError,
        "unsupported machine device cancellation outcome: #{result.outcome.inspect}"
    end
  end
end
