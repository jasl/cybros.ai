module ModelProviders
  # A tombstone survives until a file model appears or the operator resets it.
  class RemoveModelOverride < ModelDefinitionCommand
    private

      def changed_models(models, _snapshot)
        models.except(@model_ref)
      end

      def create_row
        return super unless @validate_definition

        create_policy(enabled: false, model_overrides: ModelProviderConfig.empty_overrides.merge(
          "entries" => { @model_ref => { "op" => "remove" } }
        ))
      end

      def apply_change(candidate)
        candidate.put_entry(@model_ref, { "op" => "remove" })
      end
  end
end
