require "cybros_control"

module Rho
  module Cli
    # Terminal settings reuse the Human OAuth login that connected this rho.
    class Setup
      def initialize(cli:, nexus_url: nil, public_url: nil, input: $stdin, output: $stdout, error: $stderr, env: ENV,
                     prompt: nil, provider_setup: nil, telegram_setup: nil)
        @cli, @input, @output, @error, @env = cli, input, output, error, env
        @prompt = prompt || CybrosControl::Prompt.new(input: input, output: output)
        @public_url_option = public_url
        @address_explicit = !nexus_url.to_s.empty? || !env["RHO_NEXUS_URL"].to_s.empty?
        @provider_setup = provider_setup || ->(client:) {
          CybrosControl::Setup.new(url: @cli.home.base_url, input: input, output: output, error: error,
            env: env, client: client).run
        }
        @telegram_setup = telegram_setup || ->(finish:) {
          require "rho/ingress-telegram/setup"
          Rho::IngressTelegram::Setup.new(home: @cli.home, prompt: @prompt, env: env).run(finish: finish)
        }
      end

      def run(section = nil, finish: false)
        unless [nil, "model", "telegram"].include?(section)
          raise Rho::Error, "Use rho setup, rho setup model or rho setup telegram."
        end
        raise Rho::Error, "Setup needs full or agent mode; runner-only installations use rho connect." if @cli.config.mode == "runner"
        raise Rho::Error, "--finish is only available with rho setup telegram." if finish && section != "telegram"
        return @telegram_setup.call(finish: true) if finish

        raise Rho::Error, "Setup needs an interactive terminal." unless @prompt.interactive?

        @prompt.say("rho setup")
        choose_nexus
        @prompt.say("Nexus: #{@public_url}")
        @cli.core.update_settings("nexus_public_url" => @public_url)
        @prompt.say("For a new Nexus, first create your owner account at #{@public_url}/setup.")
        @prompt.say("Use the setup secret supplied by your Nexus installation. Existing accounts can continue.")
        ensure_connection
        if section == "telegram" || (section.nil? && @prompt.confirm("Set up Telegram messaging?", default: true))
          @telegram_setup.call(finish: false)
        end
        if section != "telegram"
          configured = Rho::Config.read(@cli.home.settings_path)["default_model"]
          if @prompt.confirm("Configure a model provider as a Nexus administrator?", default: configured.to_s.empty?)
            @cli.core.with_platform_client { |client| @provider_setup.call(client: client) }
          end
        end
        configure_model unless section == "telegram"
        @prompt.say("Configuration saved. A running rho applies changes immediately; otherwise start it with `rho server`.")
        @prompt.say("Check `rho status`, then try `rho run \"Say hello\"` (a normal, potentially billed model request).")
        true
      rescue CybrosControl::Cancelled, Interrupt
        raise Rho::Error, "Setup cancelled. Settings already saved were kept."
      rescue CybrosControl::Error => error
        raise Rho::Error, error.message
      end

      private

        def choose_nexus
          unless @address_explicit || Rho::Home.bound_address(root: @cli.home.root)
            url = CybrosControl::Config.base_url(@prompt.ask("Nexus URL", default: @cli.home.base_url))
            home = Rho::Home.resolve(base_url: url, root: @cli.home.root, work_root: @cli.home.work_root)
            @cli = Rho::Cli::Terminal.new(home: home, out: @output)
          end
          @public_url = @public_url_option ? CybrosControl::Config.base_url(@public_url_option) :
            (@cli.config.nexus_public_url || @cli.home.base_url)
        end

        def ensure_connection
          daemon = @cli.core.running_daemon
          connected = if daemon
            @cli.core.status_document(daemon).dig("authority", "signed") == "signed_in"
          elsif (pointer = @cli.core.stored_connection)
            @cli.core.stored_identity(pointer)
          end
          if connected && operator_signed_in?
            @prompt.say("Keeping the existing rho and Nexus login.")
          else
            @cli.connect(public_url: @public_url)
          end
        end

        def operator_signed_in?
          @cli.core.with_platform_client { |client| client.profile.fetch }
          true
        rescue CybrosAgent::Api::Unauthorized, CybrosAgent::Credentials::PlaneUnavailable,
          CybrosAgent::DeviceFlow::AuthorizationLostError
          false
        end

        def configure_model
          rows = @cli.core.models(workload: "text_generation").select do |row|
            row.fetch("available") && row.fetch("capabilities").fetch("tool_calls", false)
          end
          if rows.empty?
            @prompt.say("Model setup is still pending: #{@public_url}/admin/model_providers")
            @prompt.say("Add a usable text model with tools, then return to rho settings or run rho setup model.")
            return
          end
          current = @cli.config.default_model
          choices = rows.map { |row| row.fetch("ref") }
          index = choices.one? ? 0 : @prompt.choose("Default model", choices: choices, default: choices.index(current) || 0)
          selected = choices.fetch(index)
          @cli.core.update_settings("default_model" => selected)
          @prompt.say("Default model saved: #{selected}")
          @prompt.say("Availability was checked without making a paid model request.")
        end
    end
  end
end
