module CybrosAgent
  module Platform
    ModelDefinition = Data.define(:model, :definition, :source, :removed)
    ModelProviderConfiguration = Data.define(:provider, :definition, :source, :models)
    DiscoveredModel = Data.define(:id, :display_name)

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
      }.freeze
    end
  end
end
