module Rho
  class Daemon
    # One shape for every refusal this surface answers: the status and the
    # error envelope ControlServer renders. `to_ary` lets it stand wherever a
    # `[status, body]` pair stood, so a handler never spells the envelope.
    Refusal = Data.define(:status, :code, :message, :extra) do
      def self.malformed(message) = new(status: 400, code: "malformed_body", message: message)

      def self.parameter_missing(key) = new(status: 400, code: "parameter_missing", message: "Missing #{key}")

      def self.unauthorized = new(status: 401, code: "unauthorized", message: "Unauthorized")

      def self.stopping = new(status: 503, code: "daemon_stopping", message: "The local daemon is stopping")

      def self.bootstrapping
        new(status: 503, code: "connection_bootstrapping",
          message: "The stored Agent connection is still being checked")
      end

      # An ensure that FAILED names its code: under the room
      # knob a bad address (`not_found`, `not_a_room`) must read differently
      # from an adoption still in flight.
      def self.workspace_unavailable(workspace = nil)
        detail = workspace&.code ? " (ensure-workspace: #{workspace.code}; see `rho status`)" : ""
        new(status: 409, code: "workspace_unavailable", message: "This daemon has no adopted workspace yet#{detail}")
      end

      def self.member_plane_unavailable
        new(status: 409, code: "member_plane_unavailable", message: "The member credential is not available")
      end

      # The executor plane's twin: no transport credential
      # stands, so the agent application has no inbox to read or commit on
      # — the fact `runner.not_placed` logs at boot.
      def self.executor_plane_unavailable
        new(status: 503, code: "executor_plane_unavailable",
          message: "The executor credential is not available; this daemon has no inbox yet")
      end

      # A `:turn_author` hook that raised: fail-closed, because a turn
      # opened without the gate its extension meant to attach would run
      # unguarded.
      def self.extension_failed(extension, error)
        new(status: 500, code: "extension_failed",
          message: "#{extension} failed while authoring the turn (#{error.class.name})")
      end

      # The kernel refused the input at materialization (`input_blocked`,
      # a durable reason — an unknown model, a refused selection): the
      # conversation stands and the input is parked at its position, so
      # the sentence names the conversation and the reason WORD verbatim,
      # the kernel's own, never re-worded.
      def self.input_blocked(conversation_public_id, reason)
        new(status: 422, code: "input_blocked",
          message: "the kernel blocked the input (#{reason}); the conversation #{conversation_public_id} stands " \
                   "with the input parked — edit or delete it through the API, or open a new turn",
          extra: { conversation: { public_id: conversation_public_id } })
      end

      # THE DOOR WORD for an address no principal of the workspace answers
      # to: `rho do --agent` resolves `@handle` or a public id
      # through the principals listing, and the refusal names what the
      # listing knows so a typo reads as one.
      def self.principal_unknown(address, handles)
        known = handles.empty? ? "the listing names nobody" : "known: #{handles.map { |handle| "@#{handle}" }.join(", ")}"
        new(status: 404, code: "principal_unknown",
          message: "no principal #{address} in this workspace (#{known})")
      end

      def self.not_followed(public_id, lane:, hint: nil)
        new(status: 404, code: "#{lane}_not_followed",
          message: ["This daemon is not following #{public_id}", hint].compact.join(" — "))
      end

      # A refusal Nexus attributes to the request is relayed as itself; the
      # rest are upstream failures. A resource's 403 remains distinct from
      # losing the daemon's credential or a transient transport failure.
      def self.from_api_error(error)
        status, fallback, extra =
          case error
          when CybrosAgent::Api::Forbidden then [403, "forbidden"]
          when CybrosAgent::Api::NotFound then [404, "not_found"]
          when CybrosAgent::Api::Conflict then [409, "conflict"]
          when CybrosAgent::Api::ContentTooLarge then [413, "content_too_large"]
          when CybrosAgent::Api::RateLimited then [429, "rate_limited", { retry_after: error.retry_after }]
          when CybrosAgent::Api::InvalidRequest then [422, "invalid_request"]
          else [502, "nexus_error"]
          end
        new(status: status, code: error.code || fallback,
          message: CybrosAgent::Redaction.call(error.message), extra: extra || {})
      end

      def initialize(status:, code:, message:, extra: {}) = super

      def to_ary = [status, { error: { code: code, message: message, **extra } }]
      alias to_a to_ary
    end
  end
end
