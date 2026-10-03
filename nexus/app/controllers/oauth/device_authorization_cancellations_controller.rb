# POST /oauth/device_authorization/cancellation — a first-party extension. The
# row-lock winner against Consume decides whether the caller may kill its poller.
class OAuth::DeviceAuthorizationCancellationsController < OAuth::MachineController
  rate_limit to: 12, within: 1.minute,
    by: -> { request.remote_ip },
    scope: "oauth/device-authorization-cancellation",
    with: -> { render_rate_limited(retry_after: 5) }

  rescue_from OAuth::InvalidRequest, with: -> { render_oauth_error(:invalid_request) }

  def create
    return render_oauth_error(:invalid_client) unless scalar_field(:client_id) == OAuth::DEVICE_CLIENT_ID
    # Keep the first-party extension tolerant of the same OAuth-library
    # compatibility parameter as the standard machine endpoints.
    scalar_field(:scope)

    raw = scalar_field(:device_code)
    return render_oauth_error(:invalid_request) if raw.nil?

    authorization = DeviceAuthorization.find_by_device_code(raw)
    return render_oauth_error(:invalid_grant) if authorization.nil?

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
