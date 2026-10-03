module ModelProviders
  class UpsertModelOverride < ModelDefinitionCommand
    def initialize(model:, **base)
      super(**base)
      @model = model
    end

    private

      def changed_models(models, _snapshot)
        models.merge(@model_ref => @model)
      end

      def create_row
        create_policy(enabled: false, model_overrides: ModelProviderPolicy.empty_overrides.merge(
          "entries" => { @model_ref => { "op" => "upsert", "model" => @model } }
        ))
      end

      def apply_change(candidate)
        candidate.put_entry(@model_ref, { "op" => "upsert", "model" => @model })
      end
  end
end
