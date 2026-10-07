require "rho"
require_relative "acp/version"
require_relative "acp/methods"
require_relative "acp/wire"
require_relative "acp/connection"

module Rho
  # THE AGENT CLIENT PROTOCOL ON RHO: the protocol layer — the framing (`Wire`),
  # the two-way loop with ids and `$/cancel_request` in both directions
  # (`Connection`), the names (`Methods`) — and `rho-acp`, the process an
  # editor, the registry or harbor spawns on stdio: a PEER SURFACE over
  # `Rho::Core` beside the CLI and the WebUI, never an extension (no
  # `rho_extensions` metadata, no `register(api)`). The protocol layer is
  # stdlib only — `json` and threads — so the harness fixtures load it by
  # load path; nothing in it knows a daemon, a kernel or a runner. The
  # client half (the `delegate_agent` tool, the `acp_agents` rows) is
  # rho-acp-client, an extension gem that depends on this one for the wire.
  # The surface itself is `Rho::Acp::Agent`:
  # `exe/rho-acp` runs it on stdio.
  module Acp
    class Error < Rho::Error; end

    # The wire or the connection ended: EOF, a closed pipe, our own close.
    class Closed < Error; end

    # A `Pending#wait` that ran past its timeout; the request stays open.
    class Unanswered < Error; end

    # The peer answered our request with a JSON-RPC error.
    class RemoteError < Error
      attr_reader :code, :data

      # A peer's error object; a code that is no integer reads as internal.
      def self.from(error)
        code = error["code"]
        code = Methods::ErrorCode::INTERNAL unless code.is_a?(Integer)
        new(code, error["message"].to_s, data: error["data"])
      end

      def initialize(code, message, data: nil)
        super(message)
        @code = code
        @data = data
      end
    end
  end
end

# The surface, after the errors it raises are defined.
require_relative "acp/agent"
