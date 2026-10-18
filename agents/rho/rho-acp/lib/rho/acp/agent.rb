require "securerandom"
require_relative "agent/sessions"
require_relative "agent/errors"
require_relative "agent/methods"
require_relative "agent/content"
require_relative "agent/mapping"
require_relative "agent/permissions"
require_relative "agent/turn"
require_relative "agent/auth"
require_relative "agent/options"
require_relative "agent/commands"
require_relative "agent/replay"
require_relative "agent/fs_port"
require_relative "agent/environment"
require_relative "agent/cli"

module Rho
  module Acp
    # THE ACP AGENT PROCESS (`rho-acp`, this gem's exe, not a Thor verb of `rho`): one connection over stdio, the sessions it speaks for, and
    # the threads that speak. `exe/rho-acp [--mode bypass|ask|rules]
    # [--model M] [--runner ID]` builds one and serves it; the flags are
    # the DEFAULTS for new sessions — the mode (`bypass`, rho's own
    # posture; an editor that wants prompts passes `--mode ask`), the
    # model (else the home's `default_model`), the runner-kind executor an
    # agent-mode rho names for the session's tools.
    #
    # FD-LEVEL HYGIENE at entry (`Wire.over_stdio`): the original fd 1 is
    # dup'd into the wire IO and STDOUT is reopened onto stderr with
    # `$stdout` pointed there too — `puts`, `warn`, the log and every child
    # spawned with an inherited stdout land on stderr; the wire IO is the
    # one holder of the descriptor (the hygiene test spawns a child with an
    # inherited stdout and asserts the wire stays JSON).
    #
    # THREADS, NOT A REACTOR: the connection's own READER parses and
    # resolves ids; `serve` drains its queue on the calling thread and
    # hands EVERY inbound request to a thread of its own (`Dispatcher`),
    # so a `session/new` waiting on the kernel never delays a
    # `session/cancel` for another session; one TURN thread per in-flight
    # `session/prompt` holds the `Core#follower_events` socket, and one PARK
    # thread per park so the follow never blocks on a person (a reader
    # that stops reading closes the daemon's stream). Every thread rescues
    # `Rho::Error`, `ConnectionError`, `Core::Deadline` and the
    # connection's own errors itself and answers the JSON-RPC error
    # (`Errors.translate`); nothing raises across threads.
    #
    # A FRESH `Rho::Core` PER METHOD (`core`): the core proves the daemon
    # once per verb, and a restarted daemon mints a new bearer.
    #
    # EXIT on stdin EOF and on SIGTERM/SIGINT (`stop`): the sessions'
    # live members released best-effort (`fs: nil`, `mcp: []` — the record
    # stays, it is the conversation's), the port stopped, exit 0; the
    # kernel turns keep running (a conversation outlives its reader; this
    # process stops nothing on EOF). A runner-mode home answers
    # `initialize` and refuses `session/new` -32603 by `RUNNER_MODE`.
    class Agent
      MODES = %w[bypass ask rules].freeze
      DEFAULT_MODE = "bypass".freeze
      RUNNER_MODE = "this rho runs in mode runner: it opens no conversations".freeze
      # The exe's stderr prefix: every sentence this process prints.
      PREFIX = "rho-acp".freeze

      attr_reader :connection, :sessions, :client, :mode, :model, :runner, :home

      # `core` is a callable answering a `Rho::Core` (or the tests'
      # double); `home` the `Rho::Home` the attachments' tmp dir hangs
      # from; `log` where the stderr sentences go.
      def initialize(wire:, core:, home:, mode: DEFAULT_MODE, model: nil, runner: nil, log: $stderr)
        raise ArgumentError, "mode must be one of #{MODES.join(", ")}" unless MODES.include?(mode)

        @connection = Connection.new(wire)
        @core_factory = core
        @home = home
        @mode = mode
        @model = model
        @runner = runner
        @log = log
        @sessions = Sessions.new
        @client = Client.new
        @dispatcher = Methods::Dispatcher.new(self)
        @fs_port = nil
        @fs_lock = Mutex.new
        @down = false
      end

      # A fresh core: one verb's worth of calls.
      def core = @core_factory.call

      # The home's `default_model`, read off the settings through a core
      # (nil when the settings name none or cannot be read).
      def default_model
        core.config.default_model
      rescue Rho::Error
        nil
      end

      # One line on stderr, prefixed; never the wire.
      def say(sentence)
        @log.puts("#{PREFIX}: #{sentence}")
        @log.flush
      rescue IOError
        nil
      end

      # THE FILE-SYSTEM PORT, started once, only when the
      # client advertised `fs` at `initialize`; nil otherwise — the surface
      # never registers a flag the client did not advertise.
      def fs_port
        return nil unless @client.fs?

        @fs_lock.synchronize { @fs_port ||= FsPort.new(self).start }
      end

      # The drain, on the calling thread, until the connection closes. A
      # `Closed` raised while answering — the editor hung up between a
      # request and its answer — is the EOF, not a failure.
      def serve
        @connection.run { |event| @dispatcher.dispatch(event) }
        nil
      rescue Closed
        nil
      ensure
        shutdown
      end

      # From a signal handler (through a thread — a trap context holds no
      # mutex): close the connection, which ends `serve`.
      def stop
        @connection.close
        nil
      end

      # Best-effort teardown, once: the live members released, the port
      # stopped, the wire closed. Every step shielded from the others.
      def shutdown
        return if @down

        @down = true
        @sessions.each { |session| Environment.release(self, session) }
        @fs_lock.synchronize { @fs_port&.stop }
        @connection.close
        nil
      end
    end
  end
end
