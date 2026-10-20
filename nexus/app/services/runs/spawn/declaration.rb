module Runs
  module Spawn
    # The catalog is captured by the caller. A child owns its selected
    # configuration independently of that call's later physical retention.
    Declaration = Data.define(:configuration, :selection, :model_selection, :fallback_models) do
      def self.for(node:, entry:, input:, catalog:)
        intent = ModelSelectionIntent.to_type.cast(input["model_selection"])
        named = input["model"].presence || intent&.model
        round = KernelTool.round_of(node)
        model = if named
          from_ref(named)
        elsif entry.model_mode == "caller"
          actual = CurrentModel.selection_of(round) || CurrentModel.for(node.run)
          Conversations::AnswerEngine::Selection.new(provider_id: actual.provider_id, model_ref: actual.model_ref,
            reasoning_effort: actual.reasoning_effort, reasoning_enabled: actual.reasoning_enabled)
        else
          from_ref(entry.declaration.default_model) if entry.declaration.default_model
        end
        return if model.nil?

        route = "#{model.provider_id}/#{model.model_ref}"
        intent ||= if named
          ModelSelectionIntent.explicit(route)
        elsif entry.model_mode == "caller"
          inherited = round&.model_selection || node.run.model_selection || ModelSelectionIntent.default(route)
          ModelSelectionIntent.new(inherited.attributes.merge("source" => "inherited"))
        else
          ModelSelectionIntent.default(route)
        end
        # Named inherited tools come from this call's captured surface. Reusing
        # the catalog in a nested child cannot restore a tool its parent lacks.
        inherited = Nexus::ToolDeclarations.narrow(Executors::TaskOperations::Context.defaults(node)["tools"],
          Array(entry.inherited_tool_names))
        configuration = AgentConfiguration.new(entry.declaration.attributes.merge(
          "executor_contexts" => Executors::TaskOperations::Context.defaults(node)["executor_contexts"],
          "default_model" => route, "delegation_catalog" => catalog,
          "tool_definitions" => Array(entry.declaration.tool_definitions) + inherited))
        new(configuration: configuration, selection: model, model_selection: intent,
          fallback_models: input["fallback_models"] || entry.declaration.fallback_models)
      end

      def self.from_ref(ref)
        parsed = Nexus::ModelRef.parse(ref)
        Conversations::AnswerEngine::Selection.new(provider_id: parsed.provider_id, model_ref: parsed.model_ref,
          reasoning_effort: nil, reasoning_enabled: nil)
      end
      private_class_method :from_ref

      def defaults
        { agent_configuration: configuration, model_selection: model_selection, fallback_models: fallback_models }
      end

      def input_fields = defaults.merge(selection.to_h)
    end
  end
end
