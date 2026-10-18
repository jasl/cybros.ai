require "mcp"

module Rho
  module Mcp
    # THE SDK'S STREAMABLE-HTTP TRANSPORT, CUSTOMIZED: `MCP::Client::HTTP` on Faraday's DEFAULT adapter, `net_http`
    # — the one the gem's streaming path is written and tested against.
    # httpx's Faraday adapter hands the gem's `on_data` no `env`, so under
    # it every SSE chunk is buffered as a plain body, `StreamAbort` never
    # fires, the SEP-1699 path is unreachable and a server that holds the
    # per-request stream open after its final response hangs the call to
    # the read timeout; `net_http` passes `env` (Faraday >= 2.1) and the
    # response is answered the moment its event arrives. Nothing of the
    # transport is ours — the gem's own is used as it is — only the
    # customizer block the gem offers:
    #
    # - `open_timeout` = the row's `startup_timeout_ms` (the connect bound,
    #   the stdio transport's read-timeout toggle's twin);
    # - `timeout` = the row's `timeout_ms` (60 000 by default) — TWO CLOCKS
    #   THAT AGREE: the announced park and Faraday's read timeout are one
    #   number, so under a park the runner's clamp fires first (park minus
    #   headroom) and Faraday's is the backstop that returns an abandoned
    #   worker when no park bounds the call (the CLI's probe);
    # - the row's `headers`, every value a secret `Redact` knows by value;
    # - `oauth:`, the row's OAuth provider when its storage holds tokens:
    # the gem sends the stored access token
    #   as `Authorization: Bearer` on every request and refreshes it on a
    #   401 itself; `run_step_up_flow!` (the gem's 403 `insufficient_scope`
    #   entry, private and pinned) is wrapped so the headless provider's
    #   validator can tell a STEP-UP refusal from a refresh that failed —
    #   the two reach the same hook with the same shape, and only the
    # step-up records a `pending_scope`. Both OAuth entries
    #   share the provider's authorization lock, which covers an HTTP
    #   worker even after its MCP caller has returned through cancellation.
    #
    # A legacy session's expiry (a 404 with a session → the gem's
    # `SessionExpiredError`, the session cleared) is not a death; the
    # reconnect-and-resend-once rule lives in `Connection`, beside the
    # notice line the model reads. No process, no group, no stderr: the
    # process-shaped members a `Connection` reads off any transport are
    # answered here as a transport with no process answers them — no pid,
    # never exited, nothing on stderr, nothing to settle, a kill that is
    # the close, a startup bound that is Faraday's `open_timeout` and so
    # has no toggle.
    class HttpTransport < MCP::Client::HTTP
      attr_reader :open_timeout, :timeout

      def initialize(url:, headers: {}, oauth: nil, open_timeout:, timeout:, max_message_bytes: MAX_MESSAGE_BYTES)
        @open_timeout = open_timeout
        @timeout = timeout
        super(url: url, headers: headers, oauth: oauth, max_message_bytes: max_message_bytes) do |faraday|
          faraday.options.open_timeout = open_timeout
          faraday.options.timeout = timeout
        end
      end

      def pid = nil

      def group_pid = nil

      def exited? = false

      def stderr_tail = ""

      def settle(_seconds) = false

      def kill = close

      def read_timeout=(_value)
        nil
      end

      private

        def run_oauth_flow!(unauthorized_error:)
          @oauth.synchronize_authorization { super }
        end

        # The gem's step-up entry, marked on the provider for its duration
        # (the gem reaches it only under `if @oauth`, and the one provider
        # rho-mcp attaches is its own).
        def run_step_up_flow!(forbidden_error:) = @oauth.synchronize_authorization { @oauth.step_up { super } }
    end
  end
end
