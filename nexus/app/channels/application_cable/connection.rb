module ApplicationCable
  class Connection < ActionCable::Connection::Base
    AUTHORITY_CHECK_INTERVAL = 30.seconds
    # THE PONG EXPECTATION, for executor-token connections only: the SDK's
    # realtime client answers every server ping with the channel action `pong`
    # on its executor-inbox subscription, and a socket that has let this many
    # pings go by unanswered is closed — a half-open socket (the laptop-sleep
    # case) is torn down within ~PONG_MISSES × BEAT_INTERVAL (3 × 3 s) and
    # `unsubscribed` clears its presence mark. COUNT-based, never wall-clock: a
    # stalled server sends no pings either, so its own pause cannot
    # mass-disconnect every executor when it resumes. Pongs are expected only
    # once the inbox subscription is established — the pong is a channel action;
    # a connection that has not subscribed cannot answer and must not be closed
    # for it. Display-side machinery only: nothing in the correctness path
    # depends on the cable, on presence, or on a heartbeat.
    PONG_MISSES = 3
    PONG_TIMEOUT_REASON = "pong_timeout".freeze

    identified_by :current_user, :current_access_token, :current_executor_token

    # Dual-mode, mirroring the HTTP families: a bearer Authorization header
    # resolves a member-plane AccessToken (the agent surface's credential)
    # or an executor-transport one (the executor's own socket, which
    # carries no member standing: `current_user` stays nil); otherwise the
    # signed session cookie resolves a browser user. One identifies or the
    # connection is rejected.
    def connect
      if request.authorization.present?
        set_bearer_principal || reject_unauthorized_connection
      else
        set_current_user || reject_unauthorized_connection
      end
    end

    # Action Cable's heartbeat is already the one periodic connection-level
    # clock. Reuse it to recheck bearer authority outside the event loop, so
    # expiry and authority changes that did not travel through a local command
    # close a stale socket without putting a query on every event broadcast —
    # and to count the pings an executor socket has left unanswered.
    def beat
      if pongs_expected? && @unanswered_pings >= PONG_MISSES
        close(reason: PONG_TIMEOUT_REASON, reconnect: true)
        return
      end
      if (current_access_token || current_executor_token) && Time.current >= @next_authority_check_at
        @next_authority_check_at = AUTHORITY_CHECK_INTERVAL.from_now
        perform_work self, :verify_current_authority
      end
      super
      @unanswered_pings += 1 if pongs_expected?
    end

    def verify_current_authority
      return if verified_member_access_token || verified_executor_token

      close(
        reason: ActionCable::INTERNAL[:disconnect_reasons][:unauthorized],
        reconnect: false
      )
    end

    # The id this connection marks its executor's row with (`presence_connection_id`): minted once per connection, so the edge write that
    # clears the mark can tell its own mark from a newer connection's.
    def presence_id
      @presence_id ||= SecureRandom.uuid
    end

    # Armed by the executor-inbox subscription; disarmed with it.
    def expect_pongs
      @unanswered_pings = 0
      @pongs_expected = true
    end

    def stop_expecting_pongs
      @pongs_expected = false
    end

    def pongs_expected?
      current_executor_token.present? && @pongs_expected == true
    end

    def pong
      @unanswered_pings = 0
    end

    # Subscriptions call this instead of trusting the connection-time model
    # instance. The eager load keeps a low-frequency authority check to one
    # query even for Human recovery and Agent steward/family predicates.
    def verified_member_access_token
      return if current_access_token.nil?

      token = AccessToken
        .eager_load(:refresh_token_family, user: [:identity, :steward])
        .find_by(id: current_access_token.id)
      token if token&.usable?
    end

    # The executor socket's fence: the credential must still be usable under
    # the executor's CURRENT epoch, so a re-pair, a revoke or a family loss
    # closes it within one authority interval — the stream name carries none.
    def verified_executor_token
      return if current_executor_token.nil?

      token = AccessToken
        .eager_load(:refresh_token_family, :task_executor)
        .find_by(id: current_executor_token.id)
      token if token&.executor_usable?
    end

    private

      def set_bearer_principal
        raw = ActionController::HttpAuthentication::Token.token_and_options(request)&.first
        return if raw.blank?

        if (token = AccessToken.authenticate_token(raw))
          self.current_access_token = token
          self.current_user = token.user
        elsif (token = AccessToken.authenticate_executor_token(raw))
          self.current_executor_token = token
        else
          return
        end
        @next_authority_check_at = AUTHORITY_CHECK_INTERVAL.from_now
      end

      def set_current_user
        if (session = Session.find_usable(cookies.signed[:session_id]))
          self.current_user = session.user
        end
      end
  end
end
