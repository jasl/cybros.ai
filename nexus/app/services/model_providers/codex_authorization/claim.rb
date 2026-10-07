module ModelProviders
  module CodexAuthorization
    # The transaction that records an exchange may go out, ending before any
    # byte leaves. The row's state is the whole precondition: a pending
    # session inside its window with no sibling dispatching may claim, and a
    # step the client never answered is simply claimed again — a user-code
    # request and a poll commit nothing single-use (RFC 8628), a resent code
    # exchange or refresh is answered by the provider itself (`invalid_grant`
    # is its fact), and a refresh that got no answer never reaches here
    # because InstallCredential closes that session.
    class Claim
      def self.call(session:, now: Time.current) = new(session:, now:).call

      def initialize(session:, now:)
        @session = session
        @now = now
      end

      def call
        ModelProviderOAuthSession.transaction do
          # The policy row is the ordering point shared with Enable/Disable:
          # whichever commits first decides whether this exchange may start.
          policy = ModelProviderConfig.lock.find_by(
            account_id: @session.account_id, provider_id: @session.provider_id
          )
          unless policy && (@session.device_start? || policy.enabled?)
            next Result.new(outcome: :provider_disabled, session: @session)
          end

          session = @session.lock!
          refusal = precondition_refusal(session)
          next Result.new(outcome: refusal, session: session) if refusal

          task = create_task(session)
          Result.new(outcome: :claimed, session: session, task: task, prepared: prepare(session))
        end
      end

      private

        def precondition_refusal(session)
          return :session_not_pending unless session.state == "pending"
          return :authorization_deadline_exceeded if window_closed?(session)
          return :exchange_in_flight if dispatching_sibling?(session)
          return :not_due if session.next_action_at && session.next_action_at > @now

          nil
        end

        # Strictly before, against the one `now` threaded through the whole
        # operation; a claim exactly at the deadline is late.
        def window_closed?(session)
          deadline = session.authorization_deadline_at
          return false if deadline.nil?

          @now >= deadline
        end

        def dispatching_sibling?(session)
          session.oauth_tasks.dispatching.exists?
        end

        def create_task(session)
          ModelProviderOAuthTask.create!(
            account_id: session.account_id,
            oauth_session: session,
            exchange_kind: session.semantic_exchange_kind,
            claimed_at: @now,
            deadline_at: dispatch_deadline(session)
          )
        end

        # The window is the bound; a session with no window yet gets the
        # full one from now.
        def dispatch_deadline(session)
          session.authorization_deadline_at ||
            @now + ModelProviderOAuthSession::AUTHORIZATION_WINDOW_SECONDS
        end

        def prepare(session)
          case session.semantic_exchange_kind
          when "user_code_request"
            Requests.user_code_request
          when "device_token_poll"
            Requests.device_token_poll(
              device_auth_id: session.device_auth_id, user_code: session.user_code
            )
          when "code_exchange"
            Requests.code_exchange(
              authorization_code: session.authorization_code, code_verifier: session.code_verifier
            )
          when "token_refresh"
            # Read through the exact triple the session froze, so a rotated
            # credential's token is never spent by an older session.
            Requests.token_refresh(refresh_token: frozen_refresh_token(session))
          else
            # Raising beats returning nil: a claim that recorded a dispatch and
            # then handed back no request would look successful.
            raise ArgumentError, "no prepared request for #{session.semantic_exchange_kind}"
          end
        end

        def frozen_refresh_token(session)
          credential = ModelProviderCredential.find_by(
            account_id: session.account_id, provider_id: session.provider_id,
            public_id: session.source_credential_public_id,
            authorization_lineage_id: session.source_authorization_lineage_id,
            generation: session.source_generation
          )
          raise ActiveRecord::RecordNotFound, "frozen credential is gone" if credential.nil?

          credential.refresh_secret
        end
    end
  end
end
