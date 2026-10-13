require_relative "agent_presets"
require_relative "run_declaration"
require_relative "preset_execution/memory"

module Rho
  # Resolve one authored Preset against this installation's current capability
  # surface. The resulting value is sent with an input; the Preset UUID never
  # becomes an answering identity or a memory owner in Nexus.
  module PresetExecution
    module_function

    def declaration(preset:, base:, kernel_tool_names: {})
      authored = preset.configuration
      selected = authored.fetch("tools")
      declaration = base.dup
      unless selected.nil?
        declaration[:tool_definitions] = base.fetch(:tool_definitions).select do |entry|
          selected.include?(entry.dig("function", "name")) || selected.include?(entry["canonical"])
        end
        declaration[:kernel_tools] = base.fetch(:kernel_tools).select do |name|
          selected.include?(name) || selected.include?(kernel_tool_names[name])
        end
      end
      runners = authored.fetch("runner_tool_names")
      allowed = base.fetch(:runner_tool_names)
      declaration[:runner_tool_names] = runners.nil? ? allowed : (allowed.nil? ? runners : runners & allowed)
      %w[prompt_template approval_mode compaction_policy lifecycle_hooks memory_context_limit conversation_reach].each do |key|
        declaration[key.to_sym] = authored.fetch(key) unless authored.fetch(key).nil?
      end
      # Installation deny rules remain the floor; Presets can add rules.
      declaration[:approval_rules] = (base.fetch(:approval_rules) + Array(authored.fetch("approval_rules"))).uniq
      declaration[:default_model] = authored.fetch("model") || base.fetch(:default_model)
      declaration[:fallback_models] = authored.fetch("fallback_models") || base.fetch(:fallback_models)
      declaration[:system_prompt] = { "content" => [RunDeclaration::GUIDELINE, authored.fetch("system_prompt")].compact.reject(&:empty?).join("\n\n") }
      declaration
    end

    # A model supplied by the person remains explicit even when it equals a
    # saved default. A prior explicit conversation selection persists; an
    # automatic selection re-resolves the Preset for the next accepted input.
    def selection(body:, declaration:, prior: nil, inherited_model: nil)
      supplied = body["model"].to_s.strip
      given = Hash.try_convert(body["model_selection"]) unless body["model_selection"].nil?
      if !body["model_selection"].nil? && given.nil?
        raise AgentPresets::Error, "model_selection must be an object"
      end
      given = given.transform_keys(&:to_s) if given
      intent = if given
        given
      elsif !supplied.empty?
        { "source" => "explicit", "model" => supplied, "constraint" => "route", "alternatives" => [] }
      elsif !body.key?("model") && prior && prior.fetch("source") == "explicit"
        prior
      else
        selected = declaration.fetch(:default_model) || inherited_model
        { "source" => "default", "model" => selected, "constraint" => "any", "alternatives" => [] }
      end
      model = intent["model"].to_s
      raise AgentPresets::Error, "Select a default model or a model for this request" if model.empty?

      fallbacks = body.key?("fallback_models") ? body.fetch("fallback_models") : declaration.fetch(:fallback_models)
      { model: model, execution_declaration: declaration.transform_keys(&:to_s), model_selection: intent, fallback_models: fallbacks }
    end

    # A child or regeneration already owns its defaults. Send only the
    # person's overrides, keeping an explicit provider route pinned even
    # when it happens to equal the captured model.
    def overrides(body:)
      fields = body.slice("model_selection", "fallback_models").transform_keys(&:to_sym)
      model = body["model"].to_s.strip
      unless model.empty?
        fields[:model] = model
        fields[:model_selection] ||= { "source" => "explicit", "model" => model, "constraint" => "route", "alternatives" => [] }
      end
      fields
    end
  end
end
