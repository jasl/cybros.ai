module CybrosAgent
  module Api
    # The base for every typed Agent API failure. `code` is the stable
    # machine-readable code from the family's error envelope when one
    # arrived; `details` is every member the envelope carried BESIDE `code`
    # and `message` — the four extended envelopes `errors.json` names
    # (`invalid_steps`' compile errors under `steps`, `stale_revision`'s
    # `current_revision`, `edge_authoring_refused`'s `path`,
    # `conversation_hosted`'s two ids) — frozen, empty when there were none,
    # so a caller branching on the code reads the fact beside it by name.
    class Error < CybrosAgent::Error
      attr_reader :code, :details

      def initialize(message = nil, code: nil, details: {})
        @code = code && Redaction.call(code)
        @details = details.to_h.transform_keys(&:to_s).freeze
        super(message || @code)
      end
    end

    # The credential is not accepted on this plane. The family answers `401`
    # identically for a credential of the other plane, a revoked or fenced
    # one, and an expired one — it never says which, and neither
    # does this error. The remedy is the same either way: present a live
    # credential of this plane, or reconnect.
    class Unauthorized < Error; end

    # The principal can browse the row but lacks the authority for this
    # command (403): owner-only management refused to a non-owner, or a
    # dedication fence answering another agent's write. Honest, unlike a 404 —
    # the resource exists and is readable; the command is not yours to give.
    class Forbidden < Error; end

    # Nothing is reachable at that address through this credential's scope —
    # absence and somebody else's record read identically.
    class NotFound < Error; end

    # The request itself is wrong: a shape, parameter, or state the server
    # refuses. A bug in the integration rather than a transient condition.
    class InvalidRequest < Error; end

    # The command lost to the resource's current state (409): a stale
    # lock_version, an in-flight transition, a taken key, a reached cap, or an
    # Idempotency-Key replayed with a different envelope. The remedy is to
    # refetch and decide again, never to blind-retry.
    class Conflict < Error; end

    # The payload exceeds a server size bound (413). Deterministic for a given
    # request: shrink the content, do not retry it as-is.
    class ContentTooLarge < Error; end

    # Transport throttling (HTTP 429): retryable after `retry_after` seconds.
    class RateLimited < Error
      attr_reader :retry_after

      def initialize(retry_after:, code: "rate_limited", details: {})
        @retry_after = retry_after
        super("rate limited; retry after #{retry_after}s", code: code, details: details)
      end
    end

    # The server failed outside the documented vocabulary — an unhandled 5xx,
    # or a status this client does not classify.
    class ServerError < Error; end

    # A success that breaks the resource contract: a payload that does not
    # match its shape, or a 2xx outside the endpoint's one expected success
    # status. Typed rather than allowed to become a nil chain three call
    # frames later.
    class MalformedResponse < Error; end
  end
end
