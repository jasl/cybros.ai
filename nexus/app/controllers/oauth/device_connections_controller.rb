# POST /oauth/device/grants/:grant_id/connection — connect a grant this
# browser context verified to the signed-in Human's server-resolved Agent
# Profile or Runner registration.
class OAuth::DeviceConnectionsController < OAuth::BrowserController
  def create
    grant = verified_grant(params[:device_grant_id])
    return redirect_to(oauth_device_path, alert: t("oauth.device.unknown_grant")) if grant.nil?

    account_wide = account_wide?
    result = DeviceAuthorizations::Connect.call(
      authorization: grant,
      connector: Current.user,
      account_wide: account_wide,
      expected_live_runner: expected_live_runner
    )

    # The flash names the same subject the pages do — a runner grant must not
    # be confirmed as a runner and then announced as an agent program.
    subject = helpers.device_grant_subject(grant)
    case result.outcome
    when :connected
      redirect_to oauth_device_grant_path(grant), notice: t("oauth.device.connected", subject: subject)
    when :stale
      # A second submit of the same Connect lands here; the page says
      # "Connection ready", so report that outcome, not "no longer available".
      if idempotent_connection?(grant.reload, account_wide: account_wide)
        redirect_to oauth_device_grant_path(grant), notice: t("oauth.device.connected", subject: subject)
      else
        flash.delete(:notice)
        redirect_to oauth_device_grant_path(grant),
          alert: t("oauth.device.connection_unavailable", subject: subject)
      end
    when :administrator_required
      redirect_to oauth_device_grant_path(grant), alert: t("oauth.device.administrator_required")
    when :shutdown_pending
      redirect_to oauth_device_grant_path(grant),
        alert: t("oauth.device.shutdown_pending", subject: subject)
    when :agent_already_bound, :not_connected
      redirect_to oauth_device_grant_path(grant), alert: t("oauth.device.#{result.outcome}")
    when :registration_changed
      redirect_to oauth_device_grant_path(grant),
        alert: t("oauth.device.runner_registration_changed")
    when :not_authorized
      redirect_to root_path, alert: t("oauth.device.member_required")
    else
      raise ArgumentError, "unsupported device connection outcome: #{result.outcome.inspect}"
    end
  end

  private

    def account_wide?
      cast_boolean(connection_params[:account_wide]) == true
    end

    def expected_live_runner
      connection_params[:expected_live_runner].to_s.presence
    end

    def connection_params
      @connection_params ||= params
        .permit(connection: %i[account_wide expected_live_runner])
        .fetch(:connection, {})
    end

    def idempotent_connection?(grant, account_wide:)
      expected_scope =
        if grant.reconnecting_live_runner?
          grant.selected_assignment_scope
        else
          account_wide ? "account_wide" : "user_private"
        end

      grant.connected? &&
        grant.connected_by_id == Current.user.id &&
        grant.connected_by_authority_generation == Current.user.authority_generation &&
        (!grant.runner_only_connection? || grant.selected_assignment_scope == expected_scope)
    end
end
