module CybrosAgent
  module DeviceFlow
    # A started authorization: the codes the human compares plus the pacing
    # facts the poller obeys. `deadline_monotonic` is the absolute stop — no
    # backoff outlives it.
    # `branch` is which connection shape this authorization started::agent resolves an Agent Profile,:runner is identity-less,
    # :combined is both on one grant — an agent that also serves as a runner
    # on its own machine. The poller needs it to name the
    # planes its credentials belong to, because the wire's `access_token`
    # carries whichever plane leads that branch.
    # `executor_kind` is the kind the request named:
    # `agent_application` on branch A and on the combined shape (the AGENT
    # address's kind — the runner's is implied, fixed `runner` by the door),
    # `runner` or `tools_provider` on branch B — what the host connected,
    # where the branch is only the credential's shape.
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
    # A combined consume adds the runner half — `runner_access_token` and
    # `runner_refresh_token`, the SECOND lineage — present only on that
    # initial poll, never on rotation (each lineage rotates on its own
    # refresh token); `runner_half` is that lineage in the transport-led
    # shape branch B mints, so `Credentials::OAuth.issue` stores it unchanged.
    Credentials = Data.define(
      :access_token, :refresh_token, :token_type, :expires_in, :executor_access_token,
      :runner_access_token, :runner_refresh_token
    ) do
      def initialize(runner_access_token: nil, runner_refresh_token: nil, **rest)
        super(**rest, runner_access_token: runner_access_token, runner_refresh_token: runner_refresh_token)
      end

      def member_plane? = !access_token.nil?
      def executor_plane? = !executor_access_token.nil?
      def runner_plane? = !runner_access_token.nil?

      def runner_half
        return nil unless runner_plane?

        with(
          access_token: nil, executor_access_token: runner_access_token,
          refresh_token: runner_refresh_token,
          runner_access_token: nil, runner_refresh_token: nil
        )
      end

      include Redacted

      def inspect
        redacted(token_type:, expires_in:, member_plane: member_plane?, executor_plane: executor_plane?,
                 runner_plane: runner_plane?,
                 hidden: %i[access_token refresh_token runner_access_token runner_refresh_token])
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
