# POST /oauth/device_authorization (RFC 8628 §3.1/3.2): starts one connection
# transaction. Malformed claims fail at issuance, before the browser connects
# the code.
class OAuth::DeviceAuthorizationsController < OAuth::MachineController
  rate_limit to: 6, within: 1.minute,
    by: -> { request.remote_ip },
    scope: "oauth/device-authorization",
    with: -> { render_rate_limited(retry_after: 60) }

  rescue_from OAuth::InvalidRequest, with: -> { render_oauth_error(:invalid_request) }

  def create
    return render_oauth_error(:invalid_client) unless scalar_field(:client_id) == OAuth::DEVICE_CLIENT_ID
    # OAuth libraries commonly send this optional scalar. Accept it for wire
    # compatibility, but never turn it into credential authority.
    scalar_field(:scope)
    # Combined = both sets complete; a half triple or a half pair is still a
    # mix, refused by the branch it falls into below.
    return create_combined_connection if combined_claims_complete?
    return create_runner_connection if scalar_field(:runner_identifier).present?
    return render_oauth_error(:invalid_request) if runner_claims_present?
    # An Agent connection has one kind, fixed by its branch: naming any is
    # a mixed request, not an ignored extra.
    return render_oauth_error(:invalid_request) if scalar_field(:executor_kind).present?

    agent_identifier = scalar_field(:agent_identifier)
    agent_display_name = scalar_field(:agent_display_name)
    executor_display_name = scalar_field(:executor_display_name)

    unless valid_identifier?(agent_identifier) && valid_name?(agent_display_name) &&
        valid_executor_display_name?(executor_display_name)
      return render_oauth_error(:invalid_request)
    end

    account = Account.first
    return render_oauth_error(:invalid_request) if account.nil?

    mint = DeviceAuthorizations::Issue.call(
      account: account,
      agent_identifier: agent_identifier,
      agent_display_name: agent_display_name,
      requested_executor_display_name: executor_display_name,
      request_ip: request.remote_ip,
      request_user_agent: request.user_agent
    )
    render_authorization(mint)
  end

  private

    def render_authorization(mint)
      public_url_options = Rails.application.routes.default_url_options

      render json: {
        device_code: mint.device_code,
        user_code: mint.authorization.formatted_user_code,
        verification_uri: oauth_device_url(**public_url_options),
        verification_uri_complete: oauth_device_url(
          **public_url_options,
          user_code: mint.authorization.formatted_user_code
        ),
        expires_in: DeviceAuthorization::TTL.to_i,
        interval: DeviceAuthorization.default_interval,
      }
    end

    # Branch B: identity-less, so agent claims are a mixed request rather than
    # an optional extra. It names its machine kind — `runner` by default,
    # `tools_provider` on request — and a value outside that vocabulary is
    # malformed, not ignored.
    def create_runner_connection
      runner_identifier = scalar_field(:runner_identifier)
      runner_display_name = scalar_field(:runner_display_name)
      executor_kind = scalar_field(:executor_kind).presence || TaskExecutor::MACHINE_KINDS.first

      return render_oauth_error(:invalid_request) if agent_claims_present?
      return render_oauth_error(:invalid_request) unless valid_runner_identifier?(runner_identifier) &&
        valid_name?(runner_display_name) && TaskExecutor::MACHINE_KINDS.include?(executor_kind)

      account = Account.first
      return render_oauth_error(:invalid_request) if account.nil?

      render_authorization(
        DeviceAuthorizations::Issue.call(
          account: account,
          runner_identifier: runner_identifier,
          runner_display_name: runner_display_name,
          requested_executor_kind: executor_kind,
          request_ip: request.remote_ip,
          request_user_agent: request.user_agent
        )
      )
    end

    # The combined shape A+B: an agent that also serves as a runner on its
    # own machine pairs both in ONE grant. The runner's kind is fixed
    # `runner` (absent or spelled), its scope fixed private at Issue.
    def create_combined_connection
      account = Account.first
      return render_oauth_error(:invalid_request) if account.nil?

      render_authorization(
        DeviceAuthorizations::Issue.call(
          account: account,
          agent_identifier: scalar_field(:agent_identifier),
          agent_display_name: scalar_field(:agent_display_name),
          requested_executor_display_name: scalar_field(:executor_display_name),
          runner_identifier: scalar_field(:runner_identifier),
          runner_display_name: scalar_field(:runner_display_name),
          request_ip: request.remote_ip,
          request_user_agent: request.user_agent
        )
      )
    end

    def combined_claims_complete?
      valid_identifier?(scalar_field(:agent_identifier)) &&
        valid_name?(scalar_field(:agent_display_name)) &&
        valid_executor_display_name?(scalar_field(:executor_display_name)) &&
        valid_runner_identifier?(scalar_field(:runner_identifier)) &&
        valid_name?(scalar_field(:runner_display_name)) &&
        scalar_field(:executor_kind).presence.in?([nil, TaskExecutor::MACHINE_KINDS.first])
    end

    # A machine request carries no Agent claims: the identifier branch is
    # the request discriminator, and the kind selector belongs to branch B alone.
    def agent_claims_present?
      scalar_field(:agent_identifier).present? ||
        scalar_field(:agent_display_name).present? ||
        scalar_field(:executor_display_name).present?
    end

    def runner_claims_present?
      scalar_field(:runner_identifier).present? ||
        scalar_field(:runner_display_name).present?
    end

    def valid_runner_identifier?(value)
      value.present? &&
        value.length <= TaskExecutor::RUNNER_IDENTIFIER_MAX_LENGTH &&
        value == value.strip &&
        value.match?(/\A[[:print:]]+\z/)
    end

    def valid_identifier?(value)
      value.present? &&
        value.length <= User::AGENT_IDENTIFIER_MAX_LENGTH &&
        value.match?(/\A[[:print:]]+\z/) &&
        value == value.strip
    end

    def valid_name?(value)
      value.present? && value.length <= User::DISPLAY_NAME_MAX_LENGTH
    end

    # An Agent connection always creates/re-pairs its agent_application
    # address. Only the display name is caller-provided.
    def valid_executor_display_name?(name)
      name.present? && name.length <= TaskExecutor::DISPLAY_NAME_MAX_LENGTH
    end
end
