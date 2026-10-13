module CybrosAgent
  module Platform
    ModelDefinition = Data.define(:model, :definition, :source, :removed)
    ModelProviderConfiguration = Data.define(:provider, :definition, :source, :models)
    DiscoveredModel = Data.define(:id, :display_name)
    ModelTest = Data.define(:outcome, :duration_ms, :http_status, :availability_update)
    ModelTestResult = Data.define(:test, :provider)

    # Configuration belongs to the administrator's surface. The member's
    # available-model listing carries no editable provider declarations.
    module ModelProviderConfigurationProjections
      include Api::ModelProviderProjections

      SHAPES = {
        ModelDefinition => {
          model: :string, definition: :optional_json_object, source: :string, removed: :boolean,
        },
        ModelProviderConfiguration => {
          provider: [:shape, Api::ModelProviders::Lane, "model_provider"],
          definition: [:optional_json_object, "configuration", "definition"],
          source: [:string, "configuration", "source"],
          models: [:shapes, ModelDefinition, "configuration", "models"],
        },
        DiscoveredModel => { id: :string, display_name: :nullable_string },
        ModelTest => {
          outcome: :string, duration_ms: :integer, http_status: :optional_integer, availability_update: :string,
        },
        ModelTestResult => {
          test: [:shape, ModelTest, "model_test"],
          provider: [:shape, Api::ModelProviders::Lane, "model_provider"],
        },
      }.freeze
    end
  end
end
