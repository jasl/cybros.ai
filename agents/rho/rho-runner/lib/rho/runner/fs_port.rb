module Rho
  class Runner
    # THE FILE-SYSTEM PORT: the editor's open buffers,
    # spoken to by `read`, `write` and `edit` — and by nothing else.
    #
    # rho-runner owns the DUCK and its errors only. An implementation (the
    # rho gem's `Extensions::Environment::FsPort`, `Net::HTTP` to the
    # surface's loopback route) is handed to the runner as a value the
    # context resolves PER CALL by the binding's anchor
    # (`ExecutionContext#port`) — never a member of the frozen
    # `ToolEnv`, so nothing frozen holds a socket and a port dropped between
    # two calls is gone at the second. The contract:
    #
    #   serves?(:read | :write)          -> bool    the client advertised that flag
    #   read_text(path, line:, limit:)   -> String  a window (both nil: the whole buffer)
    #   write_text(path, text)           -> nil     the buffer replaced
    #   drop(detail)                     -> nil     the port is unusable: leave the table
    #   client                           -> String  the client's name, for the model
    #
    # The path on the wire is the path as `ToolEnv#resolve` spells it; lines
    # are 1-based. An implementation raises ONE of the errors below and
    # nothing else the tools read: `Unavailable` (a refused connection, a
    # timeout, a 5xx, a malformed answer), `Refused` (the client said no —
    # `editor_refused`), `NotFound` (the client holds nothing for the path),
    # `BeyondEof` (a line past the last) and `Cancelled` (the request was
    # cancelled, by the worker's own signal or by the editor).
    #
    # THE ONE TABLE. The routing predicate and the two rows
    # every tool shares live here, so the tools carry no failure logic of
    # their own: a `Cancelled` is the runner's cancel path; an `Unavailable`
    # drops the port and re-raises for the caller's half — a READ falls to
    # the disk with one notice, a WRITE or EDIT answers `is_error` and
    # NEVER falls to disk after the port was asked (a disk write under a
    # dirty buffer is lost at the person's next save). `NotFound` is the
    # disk for that call, `BeyondEof` rho's beyond-EOF error, `Refused` an
    # `is_error` naming the client — each mapped by the tool it reaches.
    module FsPort
      class Error < Runner::Error; end
      class Unavailable < Error; end
      class NotFound < Error; end
      class BeyondEof < Error; end
      class Cancelled < Error; end

      # The client refused the request; `code` is the client's own word,
      # `editor_refused` for any error the table does not name.
      class Refused < Error
        EDITOR_REFUSED = "editor_refused".freeze

        attr_reader :code

        def initialize(message = nil, code: EDITOR_REFUSED)
          super(message)
          @code = code
        end
      end

      DEFAULT_CLIENT = "the editor".freeze

      # An implementation names its client; the duck's default stands
      # in for one that does not.
      def client = DEFAULT_CLIENT

      class << self
        # THE ROUTING PREDICATE: the port on the current context, when it
        # serves EVERY need (`edit` needs both flags — one consistent view
        # per call — else the disk for both halves) and the resolved path
        # is inside the env's root set; nil is the disk, never a refusal.
        def routed(env, path, *needs)
          port = ExecutionContext.current&.port
          return nil if port.nil?
          return nil unless needs.all? { |need| port.serves?(need) }

          env.in_roots?(path) ? port : nil
        end

        # THE SHARED ROWS: answers the block's value; a `Cancelled` from the
        # port becomes the runner's cancel path (the worker's own signal
        # finished the request — its reason stands; else the editor's
        # cancel, `:cancelled`); an `Unavailable` drops the port once and
        # re-raises for the caller's half of the table. Every other error
        # passes through to the tool that maps it.
        def ask(port)
          yield
        rescue Cancelled => error
          ExecutionContext.current&.raise_if_cancelled!
          raise ExecutionContext::Cancelled.new("#{port.client} cancelled the request: #{error.message}",
            reason: :cancelled)
        rescue Unavailable => error
          port.drop(error.message)
          raise
        end
      end
    end
  end
end
