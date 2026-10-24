class ModelProviderConfig
  # Saved deployment facts are a fallback, distinct from administrator overrides.
  # The same bounded document owns both; no read or inference writes this capture.
  module CatalogRetention
    extend ActiveSupport::Concern

    CATALOG_KEYS = %w[provider models model_definitions].freeze

    class_methods do
      def valid_retained_catalog_shape?(value, provider_id:)
        catalog = Hash.try_convert(value)
        return false unless catalog && (catalog.keys - CATALOG_KEYS).empty?

        models = Hash.try_convert(catalog.fetch("models", {}))
        definitions = Hash.try_convert(catalog.fetch("model_definitions", {}))
        provider = Hash.try_convert(catalog.fetch("provider", {}))
        models && definitions && provider && models.length <= MAX_OVERRIDE_REFS &&
          definitions.length <= MAX_OVERRIDE_REFS && valid_model_refs?(models.keys, provider_id: provider_id)
      end
    end

    def retained_catalog
      model_overrides.fetch("retained_catalog", {})
    end

    def retain_catalog(provider:, models:, model_definitions:)
      previous = retained_catalog
      catalog = {
        "models" => previous.fetch("models", {}).merge(models),
        "model_definitions" => previous.fetch("model_definitions", {}).merge(model_definitions),
      }
      declaration = provider || previous["provider"]
      catalog["provider"] = declaration if declaration
      self.model_overrides = model_overrides.merge("retained_catalog" => catalog)
    end
  end
end
