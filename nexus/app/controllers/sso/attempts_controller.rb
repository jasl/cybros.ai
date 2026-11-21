module Sso
  class AttemptsController < ApplicationController
    include CapabilityPageResponse
    include SsoCallbackAddress
    layout "public"
    allow_unauthenticated_access only: %i[create callback show confirm]
    rate_limit to: 30, within: 3.minutes, only: %i[create callback confirm],
      with: -> { head :too_many_requests }

    def create
      @provider = SsoProvider.find_by!(public_id: params[:provider_id])
      submitted = params.permit(:purpose, :invitation_token, :recovery_token, :action_name, :target, :current_password)
      purpose = submitted[:purpose].to_s
      return failure(:unavailable) unless @provider.enabled? || purpose == "test"
      return failure(:unauthorized_action) unless authorize_start(purpose, submitted)

      destination = sso_provider_callback_url(@provider)
      return failure(:invalid) unless destination

      state = SecureRandom.urlsafe_base64(32)
      @attempt = @provider.sso_attempts.create!(purpose: purpose, session: Current.session,
        invitation_public_id: @invitation&.public_id, member_recovery_authorization: @recovery,
        state_digest: SsoAttempt.digest(state), browser_digest: SsoAttempt.digest(browser_context),
        provider_version: @provider.lock_version, redirect_uri: destination, return_path: return_to_url,
        action_name: @action_name, action_target: @action_target, password_proved: @password_proved || false,
        code_verifier: SecureRandom.urlsafe_base64(48), nonce: SecureRandom.urlsafe_base64(32),
        expires_at: SsoAttempt::LIFETIME.from_now)
      destination = Protocol.new(@attempt.config_for_exchange).authorization_url(attempt: @attempt, state: state)
      if request.format.turbo_stream?
        # Capability pages suppress Referer. Turbo's same-origin fetch retains
        # its Origin for CSRF, then the browser must navigate to the external IdP.
        render turbo_stream: helpers.turbo_stream_action_tag(:sso_navigate, url: destination)
      else
        redirect_to destination, allow_other_host: true, status: :see_other
      end
    rescue ProtocolError
      @attempt&.destroy!
      failure(:provider_error)
    end

    def callback
      submitted = params.permit(:code, :state, :error)
      @attempt = SsoAttempt.unexpired.joins(:sso_provider).find_by(
        state_digest: SsoAttempt.digest(submitted[:state].to_s),
        sso_providers: { public_id: params[:provider_id] })
      return failure(:invalid) unless same_browser? && @attempt.claim_exchange

      provider = SsoProvider.find(@attempt.sso_provider_id)
      if submitted[:error].present? || provider.lock_version != @attempt.provider_version ||
          (!provider.enabled? && @attempt.purpose != "test")
        @attempt.destroy!
        return failure(:invalid)
      end

      profile = Protocol.new(@attempt.config_for_exchange).authenticate(attempt: @attempt, code: submitted[:code].to_s)
      unless profile.admitted
        @attempt.destroy!
        return failure(:admission_denied)
      end

      @attempt.store_profile(profile)
      complete(Resolve.call(attempt: @attempt, session: Current.session, user_agent: request.user_agent, ip_address: request.remote_ip))
    rescue ActiveRecord::RecordNotFound
      failure(:invalid)
    rescue ProtocolError
      @attempt&.destroy!
      failure(:provider_error)
    end

    def show
      return failure(:invalid) unless load_confirmation

      # This clean URL holds no capability; native confirmation POSTs need Origin.
      response.headers["Referrer-Policy"] = "same-origin"
      @local_email = case @attempt.purpose
      when "login" then @attempt.email
      when "invitation" then @attempt.account.invitations.unexpired.find_by(public_id: @attempt.invitation_public_id)&.email
      when "recovery" then @attempt.member_recovery_authorization.identity.email
      when "connect" then Current.identity.email
      else raise ArgumentError, "unsupported SSO confirmation"
      end
    end

    def confirm
      return failure(:invalid) unless load_confirmation

      result = Resolve.call(attempt: @attempt, session: Current.session, confirmed: true,
        display_name: params.permit(:display_name)[:display_name].to_s.strip,
        user_agent: request.user_agent, ip_address: request.remote_ip)
      complete(result)
    end

    private

      def authorize_start(purpose, submitted)
        case purpose
        when "login" then !authenticated?
        when "invitation"
          @invitation = Invitation.find_by_acceptance_token(submitted[:invitation_token].to_s)
          !authenticated? && @invitation && @invitation.account_id == @provider.account_id
        when "recovery"
          @recovery = MemberRecoveryAuthorization.find_by_secret(submitted[:recovery_token].to_s)
          !authenticated? && @recovery&.sso_connection? && @recovery.account_id == @provider.account_id && @recovery.consumable?
        when "test" then authenticated? && Current.user.admin? && @provider.test_candidate.ready_for_test?
        when "reauth"
          @action_name = submitted[:action_name].to_s
          @action_target = submitted[:target].to_s
          authenticated? && @action_name.match?(/\A[a-z0-9_]{1,100}\z/) &&
            @action_target.match?(/\A[a-z0-9_-]{1,128}\z/) && @provider.sso_connections.exists?(identity: Current.identity)
        when "connect"
          return false unless authenticated?
          if submitted[:current_password].present? && !Current.account.sso_only?
            @password_proved = !!Current.identity.authenticate(submitted[:current_password].to_s)
          else
            Proof.consume(session: Current.session, action: "sso_connect", target: @provider.public_id)
          end
        else false
        end
      end

      def browser_context
        session[:sso_browser] ||= SecureRandom.urlsafe_base64(32)
      end

      def same_browser?
        @attempt && session[:sso_browser].present? &&
          @attempt.browser_digest == SsoAttempt.digest(session[:sso_browser]) &&
          @attempt.session_id == Current.session&.id
      end

      def load_confirmation
        @attempt = SsoAttempt.unexpired.find_by(public_id: params[:id], phase: "confirming")
        same_browser? && @attempt.sso_provider.enabled?
      end

      def complete(result)
        case result.outcome
        when :signed_in
          adopt_session(result.session)
          redirect_to @attempt.return_path || root_path, status: :see_other
        when :confirm, :invalid_name
          alert = t("sso.invalid_name") if result.outcome == :invalid_name
          redirect_to sso_confirmation_path(@attempt.public_id), status: :see_other, alert: alert
        when :tested
          # Expose only a display hint of the provider account in the operator's result.
          hint = @attempt.subject.to_s.first(2) + "…"
          notice = t("sso.tested", issuer: @attempt.sso_provider.issuer, hint: hint,
            verified: @attempt.email_verified ? t("sso.yes") : t("sso.no"))
          redirect_to @attempt.return_path || root_path, notice: notice, status: :see_other
        when :proved, :connected, :recovered
          redirect_to @attempt.return_path || default_destination, notice: t("sso.#{result.outcome}"), status: :see_other
        else failure(result.outcome)
        end
      end

      def failure(reason)
        destination = if same_browser?
          authenticated? ? (@attempt.return_path || default_destination) : new_session_path(return_to: @attempt.return_path)
        else
          authenticated? ? root_path : new_session_path
        end
        redirect_to destination, alert: t("sso.#{reason}"), status: :see_other
      end

      def default_destination
        if authenticated?
          @attempt&.purpose == "connect" ? settings_sso_connections_path : root_path
        else
          new_session_path
        end
      end
  end
end
