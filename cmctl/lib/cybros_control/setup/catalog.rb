module CybrosControl
  class Setup
    module Catalog
      API_FORMATS = %w[openai_compatible_chat openai_responses anthropic_messages].freeze

      private

        def create_provider
          id = @prompt.ask("Provider ID")
          raise UsageError, "Provider ID must not be empty" if id.empty?

          context = @client.model_providers.provider(id)
          current = begin
            context.configuration
          rescue CybrosAgent::Api::NotFound
            nil
          end
          raise UsageError, "Provider already exists; choose Edit a provider" if current&.definition

          saved = edit_provider_definition(context, current)
          if configure_provider_credentials(context, saved.provider)
            configure_model(context)
          end
        end

        def choose_provider(providers)
          if providers.empty?
            @prompt.say("Add a custom provider first.")
            return
          end

          index = @prompt.choose("Provider", choices: providers.map(&:id))
          @client.model_providers.provider(providers.fetch(index).id)
        end

        def edit_provider_definition(context, current = context.configuration)
          definition = (current&.definition || {}).dup
          definition["base_url"] = @prompt.ask("Provider base URL", default: definition["base_url"])
          formats = (API_FORMATS + [definition["api_format"]]).compact.uniq
          index = @prompt.choose("API protocol", choices: formats, default: formats.index(definition["api_format"]) || 0)
          definition["api_format"] = formats.fetch(index)
          credentials = (%w[api_key none] + [definition["credentials"]]).compact.uniq
          index = @prompt.choose("Authentication", choices: credentials, default: credentials.index(definition["credentials"]) || 0)
          definition["credentials"] = credentials.fetch(index)
          name = @prompt.ask("Display name (optional)", default: definition["display_name"])
          definition["display_name"] = name unless name.empty?
          saved = context.set_definition(definition: definition, expected_lock_version: current&.provider&.lock_version)
          @prompt.say("Provider definition saved in Nexus.")
          saved
        end

        def configure_model(context)
          current = context.configuration
          models = current.models.reject(&:removed)
          model = unless models.empty?
            index = @prompt.choose("Model", choices: models.map(&:model) + ["Add a model"], default: models.length)
            models[index]
          end
          definition = model&.definition || {}
          id = model ? model.model.split("/", 2).last : choose_model_id(context)
          reference = "#{current.provider.id}/#{id}"
          if !model && models.any? { |row| row.model == reference }
            raise UsageError, "Model already exists; choose it from the model list to edit"
          end
          upstream = if model
            @prompt.ask("Upstream model ID", default: definition.fetch("model_id", id))
          else
            id
          end
          name = @prompt.ask("Display name (optional)", default: definition["display_name"])
          input = model_token_limit("Input token limit (blank keeps provider default)", definition.dig("capabilities", "limits", "input_tokens"))
          output = model_token_limit("Output token limit (blank keeps provider default)", definition.dig("capabilities", "limits", "output_tokens"))
          tools = @prompt.confirm("Does this model support tool calls?", default: definition.dig("capabilities", "tool_calls") != false)
          definition = ModelFields.apply(definition, model_id: upstream, display_name: name.empty? ? nil : name,
            input_tokens: input, output_tokens: output, tool_calls: tools)
          definition = configure_model_prices(definition)
          context.set_model_definition(model: reference, definition: definition, expected_lock_version: current.provider.lock_version)
          @prompt.say("Model saved: #{reference}")
          @prompt.say("No catalog prices set; cost estimates may be unavailable.") unless definition["pricing"]
        end

        def choose_model_id(context)
          models = []
          if @prompt.confirm("Read the provider's model directory?", default: true)
            @prompt.say("This lists model IDs only; it does not test inference or tool support.")
            begin
              models = context.discover_models
            rescue CybrosAgent::Error
              @prompt.say("The model directory could not be read. Enter a model ID manually.")
            end
          end
          unless models.empty?
            labels = models.map { |model| model.display_name ? "#{model.id} (#{model.display_name})" : model.id }
            index = @prompt.choose("Model ID", choices: labels + ["Enter a model ID manually"])
            return models.fetch(index).id if index < models.length
          end
          id = @prompt.ask("Model ID")
          raise UsageError, "Model ID must not be empty" if id.empty?

          id
        end

        def model_token_limit(label, current)
          loop do
            value = @prompt.ask(label, default: current&.to_s)
            return if value.empty?
            return Integer(value, 10) if value.match?(/\A[1-9][0-9]*\z/)

            @prompt.say("Enter a positive integer, or leave it blank.")
          end
        end

        def configure_model_prices(definition)
          if definition["pricing"]
            choice = @prompt.choose("Model prices", choices: ["Keep existing prices", "Edit prices", "Remove prices"])
            return definition if choice == 0
            return ModelFields.apply(definition, clear_pricing: true) if choice == 2
          elsif !@prompt.confirm("Add token prices? (optional)", default: false)
            return definition
          end

          unit = configure_cost_unit
          return definition unless unit

          input = @prompt.ask("Input price per million tokens (#{unit})", default: definition.dig("pricing", "schedule", "rates", "input_per_mtok"))
          output = @prompt.ask("Output price per million tokens (#{unit})", default: definition.dig("pricing", "schedule", "rates", "output_per_mtok"))
          if input.empty? || output.empty?
            raise UsageError, "Both prices are required when adding prices"
          end
          ModelFields.apply(definition, pricing: ModelFields.prices(definition, unit: unit, input: input, output: output))
        end
    end
  end
end
