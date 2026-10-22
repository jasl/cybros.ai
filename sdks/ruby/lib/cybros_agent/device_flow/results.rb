module CybrosAgent
  module DeviceFlow
    # A started authorization: the codes the human compares plus the pacing
    # facts the poller obeys. `deadline_monotonic` is the absolute stop — no
    # backoff outlives it.
    # Branch A resolves an Agent and its application address; branch B registers
    # a standalone Runner or tool provider. Service roles do not change this shape.
    Authorization = Data.define(
      :device_code, :user_code, :verification_uri, :verification_uri_complete,
      :interval, :expires_in, :deadline_monotonic, :branch, :executor_kind
    ) do
      include Redacted

      def inspect = redacted(user_code:, verification_uri:, hidden: %i[device_code])
    end

    # One connection's credential bundle, already sorted by plane: `access_token` is the member credential and
    # `executor_access_token` the delivery-address one. An agent connection
    # carries both; a runner carries only the address, because it is no
    # principal. The address half is never the one missing, and
    # the predicates below are what a host composes its planes from.
    Credentials = Data.define(:access_token, :refresh_token, :token_type, :expires_in, :executor_access_token) do
      def member_plane? = !access_token.nil?
      def executor_plane? = !executor_access_token.nil?
      def platform_plane? = false
      def platform_access_token = nil

      include Redacted

      def inspect
        redacted(token_type:, expires_in:, member_plane: member_plane?, executor_plane: executor_plane?,
          hidden: %i[access_token refresh_token executor_access_token])
      end
    end

    # Non-terminal poll outcomes; the poller keeps waiting.
    Pending = Data.define
    SlowDown = Data.define
    # Transport throttling (HTTP 429) seen mid-poll — distinct from protocol
    # pacing; honor Retry-After, then resume. (The public exception raised by
    # request_authorization/rotate is DeviceFlow::RateLimited.)
    Throttled = Data.define(:retry_after)
  end
end
