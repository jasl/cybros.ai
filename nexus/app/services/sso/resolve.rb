module Sso
  # Resolve the callback under the installation's admission lock. The separate
  # confirmation POST repeats the decision, so a role, invitation or competing
  # binding changed while the user read the page takes effect immediately.
  class Resolve
    Result = Data.define(:outcome, :session)
    def self.call(...) = new(...).call

    def initialize(attempt:, session:, confirmed: false, display_name: nil, user_agent: nil, ip_address: nil)
      @attempt = attempt
      @session = session
      @confirmed = confirmed
      @display_name = display_name
      @user_agent = user_agent
      @ip_address = ip_address
      @provider = attempt.sso_provider
    end

    def call
      @attempt.account.with_lock do
        @attempt.lock!
        @provider.reload
        if @session
          @session.identity.lock!
          @session.user.lock!
        end
        result = if !acceptable?
          reply(:invalid)
        else
          resolve_purpose
        end
        audit(result)
        @attempt.destroy! unless %i[confirm proved invalid_name].include?(result.outcome)
        result
      end
    rescue ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError
      reply(:invalid)
    end

    private

      def acceptable?
        @attempt.phase == "confirming" && @attempt.expires_at.future? &&
          @provider.lock_version == @attempt.provider_version &&
          (@provider.enabled? || @attempt.purpose == "test") &&
          !(@attempt.password_proved? && @attempt.account.sso_only?) &&
          @attempt.session_id == @session&.id &&
          (!@session || (Session.find_usable(@session.public_id) && !@session.identity.password_change_required?))
      end

      def resolve_purpose
        case @attempt.purpose
        when "login" then login
        when "invitation" then accept_invitation
        when "connect" then connect
        when "test" then test_configuration
        when "reauth" then reauthenticate
        when "recovery" then recover
        else raise ArgumentError, "unsupported SSO purpose"
        end
      end

      def login
        if connection
          identity = connection.identity
          identity.lock!
          member = identity.user
          member.lock!
          if member.active_human_member? && !identity.local_recovery_pending? && !identity.password_change_required?
            refresh_admission(connection)
            sign_in(identity)
          else
            reply(:unavailable)
          end
        elsif @attempt.email && Identity.exists?(email: @attempt.email)
          reply(:existing_identity)
        elsif !@provider.jit? || !@attempt.email_verified || Invitation.exists?(email: @attempt.email)
          reply(:invitation_required)
        else
          register(@attempt.email, "member")
        end
      end

      def accept_invitation
        invite = @attempt.account.invitations.unexpired.lock.find_by(public_id: @attempt.invitation_public_id)
        if !invite || connection || (@attempt.email_verified && @attempt.email != invite.email)
          reply(:invalid_invitation)
        elsif Identity.exists?(email: invite.email)
          reply(:existing_identity)
        else
          register(invite.email, invite.role, invitation: invite)
        end
      end

      def register(email, role, invitation: nil)
        return reply(:confirm) unless @confirmed
        return reply(:invalid_name) unless @display_name.present? && !@display_name.include?("\0") && @display_name.length <= User::DISPLAY_NAME_MAX_LENGTH

        identity = @attempt.account.identities.create!(email: email, sso_registration: true)
        member = @attempt.account.users.create!(kind: :human, identity: identity, role: role, display_name: @display_name)
        MemoryCollection.default_for(member)
        bind(identity)
        if invitation
          consumed = Invitation.where(id: invitation.id).where.not(expires_at: ..Time.current).delete_all
          raise ActiveRecord::RecordNotFound unless consumed == 1
        end
        sign_in(identity)
      end

      def connect
        if connection
          if connection.identity_id == @session.identity_id
            refresh_admission(connection)
            reply(:connected)
          else
            reply(:subject_in_use)
          end
        elsif @provider.sso_connections.exists?(identity_id: @session.identity_id)
          reply(:already_connected)
        elsif @confirmed
          bind(@session.identity)
          reply(:connected)
        else
          reply(:confirm)
        end
      end

      def reauthenticate
        return reply(:unavailable) unless connection && connection.identity_id == @session.identity_id

        refresh_admission(connection)
        @attempt.grant_proof
        reply(:proved)
      end

      def test_configuration
        return reply(:invalid) unless @session.user.admin?

        if @provider.accept_test(expected_version: @attempt.provider_version)
          reply(:tested)
        elsif @provider.errors.of_kind?(:base, :last_login_method)
          reply(:test_coverage_required)
        else
          reply(:invalid)
        end
      end

      def recover
        authorization = @attempt.member_recovery_authorization
        identity = authorization.identity
        identity.lock!
        identity.user.lock!
        return reply(:unavailable) unless authorization.reload.sso_connection? && authorization.consumable? && identity.local_recovery_pending?
        return reply(:subject_in_use) if connection && connection.identity_id != identity.id

        previous = identity.sso_connections.find_by(sso_provider_id: authorization.lost_sso_provider_id)
        occupied = identity.sso_connections.find_by(sso_provider: @provider)
        return reply(:already_connected) if occupied && occupied != connection && occupied != previous
        return reply(:confirm) unless @confirmed

        previous.destroy! if previous && previous != connection
        restored = connection || bind(identity)
        refresh_admission(restored)
        identity.complete_sso_recovery(authorization: authorization, connection: restored)
        reply(:recovered)
      end

      def audit(result)
        return if %i[confirm invalid_name].include?(result.outcome)
        return unless %w[test connect recovery].include?(@attempt.purpose)

        accepted = %i[tested connected recovered].include?(result.outcome)
        actor = @session&.user || @attempt.member_recovery_authorization&.user
        Audit.record(account: @attempt.account, actor: actor, target: @provider.public_id, action: @attempt.purpose,
          result: accepted ? :accepted : :refused, reason: accepted ? nil : result.outcome)
      end

      def bind(identity)
        @provider.sso_connections.create!(identity: identity, subject: @attempt.subject,
          display_name: @attempt.display_name, admission_version: @provider.admission_version)
      end

      def refresh_admission(binding)
        binding.update!(admission_version: @provider.admission_version) if binding.admission_version != @provider.admission_version
      end

      def connection
        @connection ||= @provider.sso_connections.find_by(subject: @attempt.subject)
      end

      def sign_in(identity)
        result = Sessions::Start.call(source: identity, user_agent: @user_agent, ip_address: @ip_address)
        Result.new(outcome: :signed_in, session: result.session)
      end

      def reply(outcome) = Result.new(outcome: outcome, session: nil)
  end
end
