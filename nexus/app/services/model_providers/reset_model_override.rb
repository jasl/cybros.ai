module ModelProviders
  # Reset deletes the operation, restoring the current or retained catalog entry.
  class ResetModelOverride < ModelDefinitionCommand
    private

      def changed_models(models, snapshot)
        models.except(@model_ref).merge(snapshot.models.slice(@model_ref))
      end

      def apply_change(candidate)
        candidate.delete_entry(@model_ref)
      end
  end
end
