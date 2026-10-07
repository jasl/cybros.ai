module Rho
  module Cli
    # THE CONNECTION'S LINES: what `rho status`, `rho connect` and `rho
    # disconnect` print — the running daemon's readout, the stored branch,
    # the identity per mode, the code on screen — from the documents the
    # core answers (`status_document`, `stored_connection`,
    # `stored_identity`, `stored_facts`). The run and turn renderers are
    # in `reporting.rb`; this is the same module, its ceremony half.
    module Reporting
      # The precise per-plane words stay in the code; a person reading a
      # terminal gets the ordinary login vocabulary they already know.
      SIGNED_WORDS = {
        "signed_in" => "signed in",
        "signed_out" => "not connected",
        "expired" => "credentials expired — connect again",
        "unknown" => "cannot reach Nexus to check",
      }.freeze

      private

        # The running daemon's readout, from `core.status_document`: the
        # mode, the instance, the endpoint, the signed state, the identity,
        # the planes, the workspace, the profile's two models, the default row.
        def report_running(daemon)
          document = core.status_document(daemon)
          @out.puts "mode:      #{document["mode"]}" if document["mode"]
          print_instance
          @out.puts "daemon:    running at #{daemon.fetch("endpoint")} (pid #{daemon["pid"]})"
          @out.puts "state:     #{SIGNED_WORDS.fetch(document.dig("authority", "signed"), document["state"])}"
          describe_identity(document["identity"], mode: document["mode"], runner: document["runner"])
          planes = document.dig("authority", "planes")
          planes&.each { |plane, state| @out.puts "  #{plane}: #{state}" }
          describe_workspace(document["workspace"])
          describe_models(document["profile"])
          report_adaptations(document["adaptations"], width: 13)
          document
        end

        # THE PROFILE'S TWO MODELS as the kernel answered the last
        # declaration, each saying what its absence means — the fallback
        # answers a refusal or an overload, never an unavailable model, a
        # rate limit or an error. A daemon that declared nothing yet claims
        # nothing.
        MODEL_NONE = "none (the initiator's model answers)".freeze
        FALLBACK_NONE = "none (a declined or overloaded step fails)".freeze
        FALLBACK_SCOPE = "(re-runs a step a provider declines or is overloaded for)".freeze

        def describe_models(profile)
          return if profile.nil?

          model, fallback = profile.values_at("default_model", "fallback_model")
          @out.puts "model:     #{model || MODEL_NONE}"
          @out.puts "fallback:  #{fallback ? "#{fallback} #{FALLBACK_SCOPE}" : FALLBACK_NONE}"
        end

        # The daemon's ensure-Workspace answer, mirrored as-is: pending while a
        # cycle has not settled, the adopted container with its KIND (rho's own `dedicated` workspace, or the `room` the knob named), or the typed failure.
        def describe_workspace(workspace)
          return if workspace.nil?

          case workspace["state"]
          when "adopted"
            kind = workspace["kind"] ? "#{workspace["kind"]} " : ""
            @out.puts "workspace: #{kind}#{terminal_text(workspace["name"])} (#{workspace["public_id"]})"
          when "error"
            @out.puts "workspace: error (#{workspace["code"]})"
          else
            @out.puts "workspace: pending"
          end
        end

        def terminal_text(value)
          value.to_s.gsub(/\p{Cc}/) { |character| format("\\u%04X", character.ord) }
        end

        # With no daemon there is still a durable answer on disk, and saying
        # "not connected" when a vault exists would be a lie.
        def report_stored
          pointer = core.stored_connection
          @out.puts "mode:      #{pointer ? pointer["mode"] : config.mode}"
          print_instance
          @out.puts "daemon:    not running"
          if pointer.nil?
            @out.puts "state:     not connected"
          else
            core.stored_identity(pointer)
            @out.puts "state:     connected (no daemon running)"
            describe_identity(pointer, mode: pointer["mode"], runner: nil)
          end
          report_adaptations(core.stored_facts, width: 13)
          pointer
        rescue CybrosAgent::Error, StateError, StoredConnectionError => error
          @out.puts "state:     unreadable (#{error.message})"
          nil
        end

        # THE INSTANCE: the home's own per-install part of every
        # identifier it presents, after the mode in both branches — the id is
        # the home's, so no daemon need be running to say which install this
        # is; a home never prepared has none and prints no line.
        def print_instance
          instance = @home.instance_id
          @out.puts "instance:  #{instance}" if instance
        end

        # After the two ids, LOCAL truth about rho's own runner (crit-product
        # M-4): what the daemon knows of its slot, never kernel presence —
        # a self-read would only stamp what it reads.
        def describe_identity(identity, mode: nil, runner: nil)
          return if identity.nil?

          @out.puts "profile:   #{identity["user_public_id"]}" if identity["user_public_id"]
          @out.puts "handle:    @#{identity["handle"]}" if identity["handle"]
          @out.puts "executor:  #{identity["executor_public_id"]}" if identity["executor_public_id"] && mode != "runner"
          @out.puts runner_line(identity, mode, runner) unless mode.nil?
        end

        def runner_line(identity, mode, runner)
          id = identity["runner_executor_public_id"]
          return "runner:    not registered" if id.nil? && (runner.nil? || runner["tools"].nil?)
          return "runner:    #{id} (daemon not running)" if runner.nil?
          if runner["tools"].nil?
            return "runner:    #{id} not registered (credential lost — run rho connect)" if mode == "full"
            return "runner:    #{id} stopped"
          end
          return "runner:    #{id} stopped" unless runner["running"]

          socket = runner["socket"] ? "socket connected" : "no socket"
          "runner:    #{id} serving #{runner["tools"]} tools (#{socket}, swept #{runner["swept"]})"
        end

        def announce_code(document)
          @out.puts "Open #{connection_url(document["verification_uri"])} and enter: #{document["user_code"]}"
          @out.puts "Or open directly: #{connection_url(document["verification_uri_complete"])}"
          @out.flush
        end

        # An explicit public address changes only the browser handoff, never
        # the bound home or the API/credential authority behind the ceremony.
        def connection_url(value)
          return value unless @connection_public_url

          source = URI(value)
          target = URI(@connection_public_url)
          same_origin = [source.scheme, source.host, source.port] == [target.scheme, target.host, target.port]
          return value if same_origin && source.path.start_with?("#{target.path.chomp("/")}/")

          base_path = URI(@home.base_url).path.chomp("/")
          path = source.path.delete_prefix(base_path)
          target.path = "#{target.path.chomp("/")}#{path}"
          target.query = source.query
          target.to_s
        end

        def announce_code_if_present(document)
          return false if document["user_code"].to_s.empty?

          announce_code(document)
          true
        end

        # The last line names what got paired, per mode, in the words `rho
        # status` uses (crit-product S-2).
        def report(identity, mode: nil, runner: nil)
          if identity.nil?
            @out.puts "Connected."
            return identity
          end

          user = identity["user_public_id"]
          executor = identity["executor_public_id"]
          runner_id = identity["runner_executor_public_id"]
          case mode
          when "full"
            @out.puts "Connected as #{user} — agent #{executor}, runner #{runner_id} (private to you)."
          when "agent"
            @out.puts "Connected as #{user} — agent #{executor}."
            selected = runner&.dig("selected") || config.runner
            @out.puts(selected ? "runner:    #{selected}" : "runner:    none selected — `rho run … --runner ID` names one")
          when "runner"
            @out.puts "Connected runner #{executor} (#{Rho::STANDALONE_REGISTRATION_IDENTIFIER} on #{Socket.gethostname})."
          else
            @out.puts "Connected as #{user || executor}."
          end
          identity
        end

        def report_identity(identity)
          report(
            { "user_public_id" => identity.user_public_id,
              "executor_public_id" => identity.executor_public_id,
              "runner_executor_public_id" => identity.runner_executor_public_id }.compact,
            mode: identity.mode
          )
        end
    end
  end
end
