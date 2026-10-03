module Rho
  module Acp
    class Agent
      # THE EXE'S ARGV: `rho-acp [--mode bypass|ask|rules] [--model M] [--runner
      # ID]` runs the surface on stdio; `rho-acp connect` runs the ceremony
      # on plain stdio:
      # `Cli::Connect`'s composition through the daemon when one runs, else
      # `connect_in_process`; exit 0 when connected. Hand-rolled, stdlib
      # only (the gem has no Thor): `--flag value` and `--flag=value`, an
      # unknown word or flag, a bad mode or a flag without its value → the
      # usage on stderr, exit 1 — never 0 (an editor would wait for
      # `initialize`) and never 2.
      #
      # THE HOME: `RHO_NEXUS_URL` when set, else the bound home's address,
      # else the product's — the sources `exe/rho` reads, in its order.
      class Cli
        USAGE = <<~USAGE.freeze
          usage: rho-acp [--mode bypass|ask|rules] [--model MODEL] [--runner EXECUTOR_ID]
                 rho-acp connect
        USAGE
        CONNECT = "connect".freeze
        ALREADY_CONNECTED = "this machine is already connected to Nexus".freeze
        FLAGS = %w[--mode --model --runner].freeze

        Options = Data.define(:word, :mode, :model, :runner)

        class UsageError < StandardError; end

        # `argv` → `Options`, or `UsageError`.
        def self.parse(argv)
          word = nil
          values = { "--mode" => DEFAULT_MODE, "--model" => nil, "--runner" => nil }
          rest = argv.dup
          until rest.empty?
            token = rest.shift
            if token == CONNECT && word.nil?
              word = token
            elsif token.start_with?("--")
              flag, inline = token.split("=", 2)
              raise UsageError, "unknown flag #{flag}" unless FLAGS.include?(flag)

              value = inline.nil? ? rest.shift : inline
              raise UsageError, "#{flag} needs a value" if value.nil? || value.empty? || (inline.nil? && value.start_with?("--"))

              values[flag] = value
            else
              raise UsageError, "unknown word #{token.inspect}"
            end
          end
          raise UsageError, "--mode must be one of #{MODES.join(", ")}" unless MODES.include?(values["--mode"])

          Options.new(word: word, mode: values["--mode"], model: values["--model"], runner: values["--runner"])
        end

        # The exe's whole run; answers the exit status.
        def self.run(argv, env: ENV, err: $stderr)
          options = parse(argv)
          new(options, env: env, err: err).call
        rescue UsageError => error
          err.puts("#{PREFIX}: #{error.message}")
          err.puts(USAGE)
          1
        end

        def initialize(options, env:, err:)
          @options = options
          @env = env
          @err = err
        end

        def call
          @options.word == CONNECT ? connect : serve
        end

        private

          # The ceremony on plain stdio: `Cli::Terminal#connect` prints the
          # code and the identity; a refusal is its sentence, exit 1. A
          # home ALREADY CONNECTED (a daemon whose status is active over a
          # stored pointer, `Auth.connected?`) exits 0 at once: the terminal auth method's contract is the exit, and
          # the daemon would refuse a second ceremony 409 `already_connected`.
          def connect
            terminal = Rho::Cli::Terminal.new(home: home)
            if connected?(terminal.core)
              @err.puts("#{PREFIX}: #{ALREADY_CONNECTED}")
            else
              terminal.connect
            end
            0
          rescue Rho::Error, Rho::ConnectionError => error
            @err.puts("#{PREFIX}: #{error.message}")
            1
          end

          def connected?(core)
            daemon = core.running_daemon
            !daemon.nil? && Auth.connected?(core, daemon)
          end

          # The surface: the hygiene FIRST (before anything could print),
          # then the agent on stdio until EOF or a signal; exit 0.
          def serve
            wire = Wire.over_stdio
            agent = Agent.new(wire: wire, core: -> { Rho::Core.new(home: home) }, home: home,
              mode: @options.mode, model: @options.model, runner: @options.runner, log: @err)
            %w[TERM INT].each { |signal| trap(signal) { Thread.new { agent.stop } } }
            agent.serve
            0
          rescue Rho::Error => error
            @err.puts("#{PREFIX}: #{error.message}")
            1
          end

          def home
            @home ||= Rho::Home.resolve(base_url: nexus_url)
          end

          def nexus_url
            configured = @env["RHO_NEXUS_URL"]
            return configured if configured && !configured.empty?

            Rho::Home.bound_address || Rho::Home::DEFAULT_NEXUS_URL
          end
      end
    end
  end
end
