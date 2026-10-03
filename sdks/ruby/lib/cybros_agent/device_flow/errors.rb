module CybrosAgent
  module DeviceFlow
    # The base for every typed DeviceFlow failure. `oauth_error` is the
    # top-level OAuth error string when the server supplied one.
    class Error < CybrosAgent::Error
      attr_reader :oauth_error

      def initialize(message = nil, oauth_error: nil)
        @oauth_error = oauth_error && Redaction.call(oauth_error)
        super(message || @oauth_error)
      end
    end

    # The connection is terminally lost:
    # access_denied, expired_token, refresh reuse/lapse (invalid_grant), or an
    # indeterminate refresh rotation.
    class AuthorizationLostError < Error; end

    # The monotonic authorization deadline passed before credentials arrived.
    class DeadlineExceeded < Error; end

    # The client_id or request shape was rejected — or a remote OAuth server
    # returned the standard invalid_scope code. This is an integration bug,
    # not a transient condition.
    class InvalidRequest < Error; end

    # Transport throttling (HTTP 429): retryable after `retry_after` seconds,
    # never a dead connection.
    class RateLimited < Error
      attr_reader :retry_after

      def initialize(retry_after:)
        @retry_after = retry_after
        super("rate limited; retry after #{retry_after}s")
      end
    end

    # The server failed outside the OAuth error vocabulary (an unhandled
    # 5xx, server_error, a missing or unparseable error body). It is
    # retryable where the owning operation is safe to repeat —
    # await_credentials absorbs it into the bounded transient budget —
    # while refresh rotation handles an indeterminate 5xx as terminal
    # instead.
    class ServerError < Error; end

    # Maps a terminal OAuth error string to its typed class.
    LOST = %w[access_denied expired_token invalid_grant].freeze
    INVALID = %w[invalid_client invalid_request invalid_scope unsupported_grant_type].freeze

    def self.for_oauth_error(code)
      if LOST.include?(code)
        AuthorizationLostError.new(oauth_error: code)
      elsif INVALID.include?(code)
        InvalidRequest.new(oauth_error: code)
      else
        # server_error and anything outside the OAuth vocabulary is a server
        # failure: retryable, not a lost connection.
        ServerError.new(oauth_error: code)
      end
    end
  end
end
