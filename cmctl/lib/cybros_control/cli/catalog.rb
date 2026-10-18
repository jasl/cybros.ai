module CybrosControl
  class CLI
    module Catalog
      private

        def provider_definition(command, arguments)
          fields = {}
          OptionParser.new do |parser|
            parser.on("--base-url URL") { |value| fields["base_url"] = value }
            parser.on("--api-format FORMAT") { |value| fields["api_format"] = value }
            parser.on("--credentials KIND") { |value| fields["credentials"] = value }
            parser.on("--display-name NAME") { |value| fields["display_name"] = value }
            parser.on("--concurrency-limit N", Integer) { |value| fields["concurrency_limit"] = value }
          end.parse!(arguments)
          id = one_argument(arguments, "provider #{command} requires an ID")
          context = client.model_providers.provider(id)
          current = provider_configuration(context, allow_missing: command == "add")
          if command == "add" && current&.definition
            raise UsageError, "Provider already exists; use provider edit"
          end
          definition = (current&.definition || { "api_format" => "openai_compatible_chat", "credentials" => "api_key" }).merge(fields)
          raise UsageError, "A provider requires --base-url" if definition["base_url"].to_s.empty?

          emit_configuration(context.set_definition(definition: definition, expected_lock_version: current&.provider&.lock_version))
        end

        def provider_configuration(context, allow_missing: false)
          context.configuration
        rescue CybrosAgent::Api::NotFound
          raise unless allow_missing

          nil
        end

        def provider_catalog_command(command, arguments)
          id = one_argument(arguments, "provider #{command} requires an ID")
          context = client.model_providers.provider(id)
          case command
          when "show" then emit_configuration(context.configuration)
          when "discover"
            current = context.fetch
            emit(models: context.discover_models(expected_lock_version: current.lock_version).map(&:to_h))
          when "reset"
            current = context.configuration
            emit_configuration(context.reset_definition(expected_lock_version: current.provider.lock_version))
          else raise UsageError, "Unsupported provider command"
          end
        end

        def model_definition(command, arguments)
          fields = {}
          input_price = output_price = price_unit = nil
          clear_pricing = false
          OptionParser.new do |parser|
            parser.on("--model-id ID") { |value| fields[:model_id] = value }
            parser.on("--display-name NAME") { |value| fields[:display_name] = value }
            parser.on("--input-tokens N", Integer) { |value| fields[:input_tokens] = value }
            parser.on("--output-tokens N", Integer) { |value| fields[:output_tokens] = value }
            parser.on("--[no-]tools") { |value| fields[:tool_calls] = value }
            parser.on("--input-price AMOUNT") { |value| input_price = value }
            parser.on("--output-price AMOUNT") { |value| output_price = value }
            parser.on("--price-unit UNIT") { |value| price_unit = value }
            parser.on("--clear-pricing") { clear_pricing = true }
          end.parse!(arguments)
          reference, context = model_reference(arguments, "model #{command} requires a model reference")
          if (input_price.nil? != output_price.nil?) || (price_unit && input_price.nil?) || (clear_pricing && input_price)
            raise UsageError, "Supply both --input-price and --output-price, or use --clear-pricing alone"
          end
          current = context.configuration
          model = current.models.find { |row| row.model == reference && !row.removed }
          if command == "add" && model
            raise UsageError, "Model already exists; use model edit"
          elsif command == "edit" && !model
            raise UsageError, "Model does not exist; use model add"
          end
          definition = model&.definition || {}
          pricing = if input_price
            unit = model_price_unit(price_unit)
            ModelFields.prices(definition, unit: unit, input: input_price, output: output_price)
          end
          definition = ModelFields.apply(definition, **fields, pricing: pricing, clear_pricing: clear_pricing)
          emit_configuration(context.set_model_definition(model: reference, definition: definition,
            expected_lock_version: current.provider.lock_version))
        end

        def model_price_unit(requested)
          unit = client.cost_unit.fetch.cost_unit
          if unit
            raise UsageError, "Prices must use the account cost unit #{unit}" if requested && requested != unit

            unit
          else
            raise UsageError, "Prices require --price-unit when the account cost unit is unset" if requested.to_s.empty?

            client.cost_unit.configure(requested).cost_unit
          end
        end

        def model_catalog_command(command, arguments)
          reference, context = model_reference(arguments, "model #{command} requires a model reference")
          current = context.configuration
          result = if command == "remove"
            context.remove_model_definition(model: reference, expected_lock_version: current.provider.lock_version)
          else
            context.reset_model_definition(model: reference, expected_lock_version: current.provider.lock_version)
          end
          emit_configuration(result)
        end

        def model_availability_command(command, arguments)
          reference, context = model_reference(arguments, "model #{command} requires a model reference")
          lane = context.fetch
          if command == "test"
            result = context.test_model(model: reference, expected_lock_version: lane.lock_version)
            emit(model_test: result.test.to_h, model_provider: result.provider.to_h)
          else
            result = context.set_model_availability(model: reference, available: command == "restore",
              expected_lock_version: lane.lock_version)
            emit(model_provider: result.to_h)
          end
        end

        def model_reference(arguments, message)
          reference = one_argument(arguments, message)
          provider_id, model_id = reference.split("/", 2)
          if provider_id.empty? || model_id.to_s.empty?
            raise UsageError, "Model reference must include its provider, as provider/model"
          end

          [reference, client.model_providers.provider(provider_id)]
        end

        def emit_configuration(value)
          emit(model_provider: value.provider.to_h,
            configuration: { definition: value.definition, source: value.source, models: value.models.map(&:to_h) })
        end
    end
  end
end
