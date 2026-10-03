module RealtimeConnections
  # The low-frequency authority edge: workspace access is not queried per
  # delta, and no replay fact depends on this latency-only notification.
  class Disconnect
    class << self
      def user_authority(user, reconnect: false)
        users = User.where(id: user.id).or(User.where(steward_id: user.id))
        users(users, reconnect: reconnect)
      end

      def workspace_authority(workspace)
        users(User.where(account_id: workspace.account_id).members, reconnect: true)
      end

      def credentials(tokens, reconnect: true)
        tokens.each do |token|
          disconnect(user: token.user, token: token, reconnect: reconnect) if token.member_plane?
        end
      rescue StandardError => error
        log_failure(error)
        nil
      end

      private

        # A user-wide cut addresses the cookie connection and every
        # member-token connection explicitly.
        def users(relation, reconnect:)
          relation.find_each do |user|
            disconnect(user: user, token: nil, reconnect: reconnect)
          end
          tokens = AccessToken.where(
            user_id: relation.select(:id), credential_plane: :member, revoked_at: nil
          )
          tokens = tokens.where(expires_at: nil).or(tokens.where(expires_at: Time.current..))
          tokens
            .includes(:user)
            .find_each do |token|
              disconnect(user: token.user, token: token, reconnect: reconnect)
            end
        rescue StandardError => error
          log_failure(error)
          nil
        end

        # EVERY IDENTIFIER THE CONNECTION DECLARES, or Action Cable refuses
        # the lookup (`RemoteConnections#where` validates the full set). The
        # executor identity is nil here on purpose: this is the MEMBER
        # socket's cut; an executor socket carries no user and no member
        # token and is never matched (the cable's `beat` closes it when its
        # own credential stops being usable).
        def disconnect(user:, token:, reconnect:)
          ActionCable.server.remote_connections
            .where(current_user: user, current_access_token: token, current_executor_token: nil)
            .disconnect(reconnect: reconnect)
        end

        def log_failure(error)
          Rails.error.report(error, handled: true, context: { event: "realtime_authority_disconnect_failed" })
        end
    end
  end
end
