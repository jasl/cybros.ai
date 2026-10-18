require "rho/runner"

module Rho
  module Mcp
    class Error < Rho::Runner::Error; end
    # A server that could not be connected or listed at load, or restarted
    # for a call: the sentence is `rho mcp`'s `down:` line.
    class Unavailable < Error; end
    # The transport died under a call, or a restart failed: `outcome: failed`.
    class ServerGone < Error; end
    # The server answered a JSON-RPC error other than -32602, asked for
    # input, or the call is otherwise refused before it ran: `failed`.
    class CallRefused < Error; end
    class Closed < Error; end
  end
end
