require_relative "cli/catalog"

module CybrosControl
  class CLI
    include Catalog

    HELP = <<~TEXT.freeze
      Usage: cmctl [--home DIR] COMMAND

        login --url URL --email EMAIL [--password-stdin]
        setup --url URL
        status
        logout [--local]
        providers
        models [--workload NAME] [--available]
        model hide REF
        model unhide REF
        model test REF
        model invalidate REF
        model restore REF
        model add REF [--model-id ID] [--input-tokens N] [--output-tokens N] [--tools|--no-tools]
        model edit REF [same options] [--display-name NAME] [--clear-pricing]
        model remove REF
        model reset REF
        provider add ID --base-url URL [--api-format FORMAT] [--credentials api_key|none]
        provider edit ID [--base-url URL] [--api-format FORMAT] [--display-name NAME] [--concurrency-limit N]
        provider show ID
        provider discover ID
        provider reset ID
        provider enable ID
        provider disable ID
        provider key set ID [--stdin]
        provider key clear ID
        account cost-unit UNIT
        account retention [DAYS|off]

      Passwords and API keys are prompted without echo, or read as one line from
      stdin when explicitly requested. They are never command-line arguments.
      Results are JSON. The saved API session lives under CMCTL_HOME or ~/.cmctl.
      Model prices are optional: --input-price AMOUNT --output-price AMOUNT
      [--price-unit UNIT]. Rates are per million tokens in the account cost unit.
      Provider discovery syncs model availability from a complete directory.
      Missing models become invalid; manual hiding is kept. It does not run inference.
      Model test sends a fixed inference request and may incur provider charges.
    TEXT

    def initialize(input: $stdin, output: $stdout, error: $stderr, env: ENV,
                   sessions: nil, clients: nil)
      @input, @output, @error, @env = input, output, error, env
      @sessions = sessions || ->(url) { CybrosAgent::Sessions.new(base_url: url) }
      # Allow the server's bounded 30-second model probe to return its result.
      @clients = clients || ->(url, token) { CybrosAgent::PlatformClient.new(base_url: url, credential: token, request_timeout: 45) }
    end

    def run(arguments)
      arguments = arguments.dup
      home = @env.fetch("CMCTL_HOME") { File.join(Dir.home, ".cmctl") }
      OptionParser.new do |parser|
        parser.on("--home DIR") { |value| home = value }
        parser.on("-h", "--help") { @output.puts(HELP); return 0 }
      end.order!(arguments)
      @config = Config.new(home: home)

      command = arguments.shift
      case command
      when nil, "help", "--help", "-h" then @output.puts(HELP)
      when "login" then login(arguments)
      when "setup" then setup(arguments)
      when "status" then status(arguments)
      when "logout" then logout(arguments)
      when "providers"
        no_arguments(arguments)
        emit(model_providers: client.model_providers.list.map(&:to_h))
      when "models" then models(arguments)
      when "model" then model(arguments)
      when "provider" then provider(arguments)
      when "account" then account(arguments)
      else raise UsageError, "Unknown command; run cmctl help"
      end
      0
    rescue OptionParser::ParseError
      @error.puts("Invalid options; run cmctl help")
      2
    rescue UsageError => error
      @error.puts(error.message)
      2
    rescue CybrosAgent::Api::Error => error
      # A server response is not a diagnostic channel for submitted secrets.
      # The stable code is enough to act on a failure without echoing a body.
      @error.puts("Nexus refused the request: #{error.code || error.class.name.split("::").last}")
      1
    rescue CybrosAgent::Error
      @error.puts("Cannot complete the Nexus request; check the server and connection")
      1
    rescue Error => error
      @error.puts(error.message)
      1
    rescue SystemCallError, IOError
      @error.puts("Cannot access the session file or input/output")
      1
    rescue Interrupt
      @error.puts("Interrupted")
      130
    end

    private

      def setup(arguments)
        url = nil
        OptionParser.new do |parser|
          parser.on("--url URL") { |value| url = value }
        end.parse!(arguments)
        no_arguments(arguments)
        raise UsageError, "setup requires --url" if url.to_s.empty?

        Setup.new(url: url, input: @input, output: @output, error: @error, env: @env,
          sessions: @sessions, clients: @clients).run
      end

      def login(arguments)
        url = email = nil
        from_stdin = false
        OptionParser.new do |parser|
          parser.on("--url URL") { |value| url = value }
          parser.on("--email EMAIL") { |value| email = value }
          parser.on("--password-stdin") { from_stdin = true }
        end.parse!(arguments)
        no_arguments(arguments)
        raise UsageError, "login requires --url and --email" if url.to_s.empty? || email.to_s.empty?
        raise Error, "Already logged in; run cmctl logout before connecting again" if @config.present?

        url = Config.base_url(url)
        password = secret("Password", from_stdin: from_stdin)
        grant = @sessions.call(url).create(email: email, password: password)
        connected = @clients.call(url, grant.token)
        begin
          profile = connected.profile.fetch
          unless profile.member.kind == "human" && %w[owner admin].include?(profile.member.role)
            raise Error, "An active Human owner or administrator is required"
          end
          @config.write(base_url: url, token: grant.token)
        rescue Error, CybrosAgent::Error, SystemCallError, IOError
          # A failed local login must not leave a newly minted API session.
          # Revocation failure never replaces the original failure.
          begin
            connected.session.revoke
          rescue CybrosAgent::Error
            nil
          end
          raise
        end
        emit(connected: true, base_url: url, session: grant.session.to_h)
      end

      def status(arguments)
        no_arguments(arguments)
        credentials = @config.read
        profile = client.profile.fetch
        emit(base_url: credentials.base_url, session: client.session.fetch.to_h,
          member: profile.member.to_h, credential_plane: profile.credential_plane)
      end

      def logout(arguments)
        local = false
        OptionParser.new do |parser|
          parser.on("--local") { local = true }
        end.parse!(arguments)
        no_arguments(arguments)
        if @config.present? && !local
          begin
            client.session.revoke
          rescue CybrosAgent::Api::Unauthorized
            # An expired or already revoked session can be forgotten locally.
            nil
          end
        end
        @config.delete
        emit(logged_out: true, local_only: local)
      end

      def models(arguments)
        workload = nil
        available = nil
        OptionParser.new do |parser|
          parser.on("--workload NAME") { |value| workload = value }
          parser.on("--available") { available = true }
        end.parse!(arguments)
        no_arguments(arguments)
        rows = client.models.list(workload: workload, available: available).map do |model|
          model.to_h.merge(pricing: model.pricing.to_h)
        end
        emit(models: rows)
      end

      def model(arguments)
        command = arguments.shift
        return model_definition(command, arguments) if %w[add edit].include?(command)
        return model_catalog_command(command, arguments) if %w[remove reset].include?(command)
        return model_availability_command(command, arguments) if %w[test invalidate restore].include?(command)

        unless %w[hide unhide].include?(command)
          raise UsageError, "Expected model add, edit, remove, reset, hide, unhide, test, invalidate or restore"
        end
        reference = one_argument(arguments, "model #{command} requires a model reference")
        provider_id, model_id = reference.split("/", 2)
        if provider_id.empty? || model_id.to_s.empty?
          raise UsageError, "Model reference must include its provider, as provider/model"
        end

        context = client.model_providers.provider(provider_id)
        lane = context.fetch
        result = context.set_model_visibility(model: reference, visible: command == "unhide",
          expected_lock_version: lane.lock_version)
        emit(model_provider: result.to_h)
      end

      def provider(arguments)
        command = arguments.shift
        case command
        when "add", "edit" then provider_definition(command, arguments)
        when "show", "discover", "reset" then provider_catalog_command(command, arguments)
        when "enable", "disable"
          id = one_argument(arguments, "provider #{command} requires an ID")
          context = client.model_providers.provider(id)
          lane = context.fetch
          # Read once, then send that version. A concurrent edit is a conflict
          # for the operator to resolve, never an automatic overwrite/retry.
          result = if command == "enable"
            context.enable(expected_lock_version: lane.lock_version)
          else
            context.disable(expected_lock_version: lane.lock_version)
          end
          emit(model_provider: result.to_h)
        when "key" then provider_key(arguments)
        else raise UsageError, "Expected provider add, edit, show, discover, reset, enable, disable or key"
        end
      end

      def provider_key(arguments)
        command = arguments.shift
        case command
        when "set"
          from_stdin = false
          OptionParser.new do |parser|
            parser.on("--stdin") { from_stdin = true }
          end.parse!(arguments)
          id = one_argument(arguments, "provider key set requires an ID")
          context = client.model_providers.provider(id)
          key = secret("Provider API key", from_stdin: from_stdin)
          emit(model_provider: context.install_api_key(key).to_h)
        when "clear"
          id = one_argument(arguments, "provider key clear requires an ID")
          emit(model_provider: client.model_providers.provider(id).remove_api_key.to_h)
        else raise UsageError, "Expected provider key set or clear"
        end
      end

      def account(arguments)
        case arguments.shift
        when "cost-unit"
          unit = one_argument(arguments, "account cost-unit requires a UNIT")
          emit(account: client.cost_unit.configure(unit).to_h)
        when "retention"
          retention(arguments)
        else
          raise UsageError, "Expected account cost-unit UNIT or account retention [DAYS|off]"
        end
      end

      def retention(arguments)
        if arguments.empty?
          emit(account: client.retention.fetch.to_h)
        else
          value = one_argument(arguments, "account retention accepts DAYS or off")
          unless value == "off" || value.match?(/\A[1-9][0-9]*\z/)
            raise UsageError, "Retention must be a positive number of days or off"
          end
          days = value == "off" ? nil : Integer(value, 10)
          emit(account: client.retention.update(execution_details_retention_days: days).to_h)
        end
      end

      def client
        @client ||= begin
          credentials = @config.read
          @clients.call(credentials.base_url, credentials.token)
        end
      end

      def secret(label, from_stdin:)
        if from_stdin
          value = @input.gets
        elsif @input.tty?
          @error.print("#{label}: ")
          value = @input.noecho(&:gets)
          @error.puts
        else
          raise UsageError, "Use the explicit stdin option for non-interactive secret input"
        end
        value = value.to_s.chomp
        raise UsageError, "#{label} must not be empty" if value.empty?

        value
      end

      def one_argument(arguments, message)
        raise UsageError, message unless arguments.length == 1 && !arguments.first.empty?

        arguments.first
      end

      def no_arguments(arguments)
        raise UsageError, "Unexpected arguments; run cmctl help" unless arguments.empty?
      end

      def emit(value)
        @output.puts(JSON.pretty_generate(value))
      end
  end
end
