require_relative "setup/provider"
require_relative "setup/authorization"
require_relative "setup/catalog"

module CybrosControl
  # Standalone setup owns a temporary Human API session. An application may
  # supply its own authenticated Platform client and retain its OAuth owner.
  class Setup
    include Provider
    include Authorization
    include Catalog

    def initialize(url:, input: $stdin, output: $stdout, error: $stderr, env: ENV,
                   prompt: nil, sessions: nil, clients: nil, sleeper: nil, clock: nil, client: nil)
      @url = Config.base_url(url)
      @prompt = prompt || Prompt.new(input: input, output: output)
      @error = error
      @sessions = sessions || ->(base_url) { CybrosAgent::Sessions.new(base_url: base_url) }
      @clients = clients || ->(base_url, token) { CybrosAgent::PlatformClient.new(base_url: base_url, credential: token) }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @client = client
      @supplied_client = !client.nil?
    end

    def run
      unless @prompt.interactive?
        raise UsageError, "Setup needs an interactive terminal. Run cmctl setup --url URL in a terminal."
      end

      @prompt.say("Model provider setup — #{@url}")
      unless @supplied_client
        @prompt.say("Sign in as a Nexus owner or administrator. This login is only used during setup.")
        sign_in
      end
      require_administrator
      loop do
        configure_provider
        break unless @prompt.confirm("Configure another provider?", default: false)
      end
      report_models
      true
    ensure
      sign_out unless @supplied_client
    end

    private

      def sign_in
        email = @prompt.ask("Nexus email")
        password = @prompt.ask("Nexus password", secret: true)
        raise UsageError, "Email and password must not be empty" if email.empty? || password.empty?

        grant = @sessions.call(@url).create(email: email, password: password)
        @session_public_id = grant.session.public_id
        @client = @clients.call(@url, grant.token)
      end

      def require_administrator
        profile = @client.profile.fetch
        unless profile.member.kind == "human" && %w[owner admin].include?(profile.member.role)
          raise Error, "An active Human owner or administrator is required. Ask your administrator to configure providers."
        end
      end

      def sign_out
        return unless @client

        @client.session.revoke
      rescue CybrosAgent::Api::Unauthorized
        # Expired or already revoked is also no longer usable.
        nil
      rescue CybrosAgent::Error
        @error.puts("Could not revoke setup API session #{@session_public_id}. Remove it at #{@url}/settings/sessions; it was not saved locally.")
      ensure
        @client = nil
      end

      def configure_cost_unit
        unit = @client.cost_unit.fetch.cost_unit
        if unit
          @prompt.say("Account cost unit: #{unit} (kept)")
          return unit
        end

        @prompt.say("Prices use one account cost unit, which can only be set once.")
        unit = @prompt.ask("Account cost unit", default: "USD")
        if @prompt.confirm("Set the account cost unit to #{unit}?")
          @client.cost_unit.configure(unit).cost_unit
        else
          @prompt.say("Cost unit left unset. Model prices were not changed.")
          nil
        end
      end

      def report_models
        models = @client.models.list(workload: "text_generation", available: true)
        usable = models.select(&:tool_calls?)
        if usable.empty?
          @prompt.say("No usable tool-calling model is available yet. Check provider credentials, visibility and tool-call support.")
        else
          @prompt.say("Available tool-calling models: #{usable.length}. Choose rho's default model in rho setup.")
        end
        @prompt.say("Settings have been saved. No paid model request was sent; verify with a first conversation.")
      end
  end
end
