require "io/console"

module Rho
  module Cli
    # THE CEREMONY'S WAIT-AND-PRINT: a human connects before there is
    # anything to connect to — through the daemon's endpoints when one
    # runs (never two ceremonies for one home), else the identical flow
    # in-process under the same boot lock. The core holds the three
    # primitives (`start_ceremony`, `status_document`,
    # `connect_in_process`); this mixin holds the two waits a terminal
    # adds around them and the lines it prints through `Reporting`.
    module Connect
      POLL_INTERVAL = 1
      # The daemon answers 503 connection_bootstrapping between binding and
      # finishing the staging inspection, usually well under a second; a
      # human racing that window is waited through it. Bounded: a daemon
      # stuck there is broken.
      BOOTSTRAP_WAIT = 30

      def connect(public_url: nil, api_key: false, api_key_stdin: false, input: $stdin)
        if api_key || api_key_stdin
          raise ConnectionError, "Choose --api-key or --api-key-stdin" if api_key && api_key_stdin

          document = read_api_keys(input, stdin: api_key_stdin)
          connected = core.import_api_keys(document)
          return report(connected.fetch("identity"))
        end

        @connection_public_url = public_url || config.nexus_public_url
        daemon = core.running_daemon
        return connect_through(daemon) if daemon

        report_identity(core.connect_in_process { |code| announce_code(code) })
      ensure
        @connection_public_url = nil
      end

      # THE PAIR OF CONNECT: revoke and forget — the runner
      # half alone with `--runner` — then the lines that say what ended.
      def disconnect = report_disconnect(core.disconnect)

      private

        def read_api_keys(input, stdin:)
          if stdin
            raw = input.read(65_537)
            raise ConnectionError, "API key input is too large" if raw.bytesize > 65_536

            raise ConnectionError, "API key input must be a JSON object" unless raw.lstrip.start_with?("{")

            return JSON.parse(raw)
          end
          unless input.tty?
            raise ConnectionError, "Use --api-key-stdin with a JSON object when no terminal is attached"
          end

          fields = APIKeys::FIELDS
          labels = { "access_token" => "Agent member API key", "executor_access_token" => "Executor API key" }
          fields.to_h { |field| [field, input.getpass("#{labels.fetch(field)}: ")] }
        rescue JSON::ParserError
          raise ConnectionError, "API key input must be a JSON object"
        end

        # ONE start per attempt, retried only on the daemon's own
        # bootstrapping code and only inside the bound; every other refusal
        # is the answer as it came.
        def start_ceremony(daemon)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOTSTRAP_WAIT
          loop do
            started = core.start_ceremony(daemon)
            # The daemon reports failure as an envelope or a bare string
            # (`failure_message` reads both); only the envelope form can carry
            # the bootstrapping code.
            error = Hash.try_convert(started["error"])
            unless error && error["code"] == "connection_bootstrapping" &&
                Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
              return started
            end

            sleep POLL_INTERVAL
          end
        end

        def connect_through(daemon)
          started = start_ceremony(daemon)
          raise ConnectionError, core.failure_message(started) if failed?(started)
          return report(started["identity"]) if started["phase"] == "active"

          code_announced = announce_code_if_present(started)
          loop do
            status = core.status_document(daemon)
            connection = status["connection"] || {}
            raise ConnectionError, core.failure_message(connection) if connection["phase"] == "error"
            code_announced = announce_code_if_present(connection) unless code_announced

            case status["state"]
            when "active"
              # Report only the completed ceremony or an already signed-in connection.
              phase = connection["phase"]
              if phase == "active" || (phase.nil? && status.dig("authority", "signed") == "signed_in")
                return report(status["identity"], runner: status["runner"])
              end
              raise ConnectionError, "the connection is no longer in flight" if phase.nil?
            when "disconnected"
              # Disconnected with nothing in flight is not "still connecting":
              # there is no ceremony left to wait for.
              raise ConnectionError, "the connection is no longer in flight" if status["connection"].nil?
            else nil # connecting: the ceremony is still in flight.
            end
            sleep POLL_INTERVAL
          end
        end

        def failed?(document) = document["error"] || document["phase"] == "error"
    end
  end
end
