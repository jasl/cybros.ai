require_relative "model_provider_configuration"

module CybrosAgent
  module Platform
    # The same model and lane projections as the member's read surface;
    # administrator credentials reach them through the Platform API.
    class ModelCatalog < Api::ModelCatalog
      PATH = "/api/v1/admin/models".freeze

      # Operators see the complete catalog unless they request only
      # available rows; unavailable reasons explain what needs configuring.
      def list(workload: nil, available: nil)
        read_models(query(workload:, available: available&.to_s))
      end
    end

    class ModelProviders < Api::ModelProviders
      PATH = "/api/v1/admin/model_providers".freeze

      def provider(provider_id)
        ModelProviderContext.new(dispatch: @dispatch, provider_id: provider_id)
      end
    end

    # Serving control carries the version it was read at. A stale writer
    # receives Conflict; the client never retries a write with a newer version.
    class ModelProviderContext
      include ModelProviderConfigurationProjections
      include Api::WorkspaceProjections

      def initialize(dispatch:, provider_id:)
        @dispatch = dispatch
        @provider_id = required_string_snapshot(provider_id, "provider_id")
      end

      def fetch
        shape(Api::ModelProviders::Lane, @dispatch.call(path), "model_provider")
      end

      def configuration
        shape(ModelProviderConfiguration, @dispatch.call(path))
      end

      def set_definition(definition:, expected_lock_version:)
        write_configuration("definition", :put, definition: definition, expected_lock_version: expected_lock_version)
      end

      def reset_definition(expected_lock_version:)
        write_configuration("definition", :delete, expected_lock_version: expected_lock_version)
      end

      def set_model_definition(model:, definition:, expected_lock_version:)
        write_configuration("model_definition", :put,
          model: model, definition: definition, expected_lock_version: expected_lock_version)
      end

      def remove_model_definition(model:, expected_lock_version:)
        write_configuration("model_definition", :delete, model: model, expected_lock_version: expected_lock_version)
      end

      def reset_model_definition(model:, expected_lock_version:)
        write_configuration("model_definition/reset", :post, model: model, expected_lock_version: expected_lock_version)
      end

      # This reads the provider's model directory. It neither runs a model
      # nor verifies that a listed model supports a particular capability.
      def discover_models
        shapes(DiscoveredModel, @dispatch.call("#{path}/model_discovery", method: :post), "models")
      end

      def authorization
        ProviderAuthorizationContext.new(dispatch: @dispatch, path: "#{path}/authorization")
      end

      def enable(expected_lock_version: nil) = serving(true, expected_lock_version)
      def disable(expected_lock_version:) = serving(false, expected_lock_version)

      # Visibility keeps the model's definition and pricing intact. Its
      # optimistic version belongs to the provider's existing policy row.
      def set_model_visibility(model:, visible:, expected_lock_version:)
        shape(Api::ModelProviders::Lane, @dispatch.call("#{path}/model_visibility", method: :put, body: {
          "command" => { "model" => model, "visible" => visible, "expected_lock_version" => expected_lock_version },
        }), "model_provider")
      end

      # Installation and rotation are one verb: identical material is a no-op.
      def install_api_key(api_key)
        shape(Api::ModelProviders::Lane, @dispatch.call("#{path}/api_key", method: :put,
          body: { "command" => { "api_key" => api_key } }), "model_provider")
      end

      def remove_api_key
        shape(Api::ModelProviders::Lane, @dispatch.call("#{path}/api_key", method: :delete), "model_provider")
      end

      private

        def path = "#{ModelProviders::PATH}/#{path_segment(@provider_id, "provider_id")}"

        def write_configuration(resource, method, **command)
          answer = @dispatch.call("#{path}/#{resource}", method: method,
            body: { "command" => command.transform_keys(&:to_s) })
          shape(ModelProviderConfiguration, answer)
        end

        def serving(enabled, expected_lock_version)
          shape(Api::ModelProviders::Lane, @dispatch.call("#{path}/lane", method: :put, body: {
            "command" => { "enabled" => enabled, "expected_lock_version" => expected_lock_version },
          }), "model_provider")
        end
    end
  end
end

require_relative "provider_authorization"
