module CybrosControl
  class Setup
    module Provider
      private

        def configure_provider
          providers = @client.model_providers.list

          labels = providers.map do |provider|
            status = provider.ready? ? "configured" : "needs setup"
            "#{provider.id} (#{provider.credentials}; #{status})"
          end
          current = if providers.empty?
            1
          else
            providers.any?(&:ready?) ? providers.length : 0
          end
          choices = labels + ["Keep existing providers and continue", "Add a custom provider", "Add or edit models", "Edit a provider"]
          index = @prompt.choose("Choose a model provider", choices: choices, default: current)
          return if index == providers.length
          if index == providers.length + 1
            create_provider
          elsif index == providers.length + 2
            context = choose_provider(providers)
            configure_model(context) if context
          elsif index == providers.length + 3
            context = choose_provider(providers)
            edit_provider_definition(context) if context
          else
            provider = providers.fetch(index)
            configure_provider_credentials(@client.model_providers.provider(provider.id), provider)
          end
        end

        def configure_provider_credentials(context, provider)
          case provider.credentials
          when "api_key"
            return unless configure_key(context, provider)
            enable_provider(context)
          when "oauth_tokens"
            enable_provider(context)
            configure_authorization(context)
          when "none"
            enable_provider(context)
          else
            raise Error, "This provider's credential method is not supported by setup"
          end
          true
        end

        def configure_key(context, provider)
          if provider.configured?
            choice = @prompt.choose("An API key is already configured for #{provider.id}.",
              choices: ["Keep existing key", "Replace key", "Clear key"])
            case choice
            when 0 then return true
            when 1 then nil
            when 2
              if @prompt.confirm("Clear the API key for #{provider.id}?", default: false)
                context.remove_api_key
                @prompt.say("API key cleared.")
              end
              return false
            else raise Error, "Invalid key choice"
            end
          end
          key = @prompt.ask("#{provider.id} API key", secret: true)
          raise UsageError, "API key must not be empty" if key.empty?

          context.install_api_key(key)
          @prompt.say("API key saved in Nexus.")
          true
        end

        def enable_provider(context)
          lane = context.fetch
          return if lane.enabled?

          context.enable(expected_lock_version: lane.lock_version)
          @prompt.say("Provider enabled.")
        end
    end
  end
end
