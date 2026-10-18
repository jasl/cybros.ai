require "test_helper"
require "rho/preset_execution"

class PresetExecutionTest < Minitest::Test
  def preset(**configuration)
    Rho::AgentPresets::Entry.new(public_id: SecureRandom.uuid_v7, name: "Custom", description: "Do the work",
      configuration: Rho::AgentPresets::DEFAULT_CONFIGURATION.merge(configuration.transform_keys(&:to_s)), role: nil)
  end

  def base
    { tool_definitions: [{ "function" => { "name" => "own_tool" } }, { "canonical" => "nexus.code", "function" => { "name" => "code" } }],
      kernel_tools: ["nexus.memory.read", "nexus.memory.write"], runner_executor_public_ids: ["runner-1"],
      runner_tool_names: %w[read grep bash], approval_mode: "bypass", approval_rules: [{ "tool" => "bash", "verdict" => "deny" }],
      prompt_mechanism: "assembly", prompt_template: {}, compaction_policy: { "mode" => "kernel" },
      image_model: "dev/image", default_model: "a/first", fallback_models: ["b/second", "c/third"] }
  end

  def test_compilation_narrows_capabilities_without_creating_or_selecting_an_identity
    declaration = Rho::PresetExecution.declaration(preset: preset(system_prompt: "Be concise", tools: %w[own_tool memory_read],
      runner_tool_names: %w[read edit], model: "custom/model", fallback_models: []), base: base,
      kernel_tool_names: { "nexus.memory.read" => "memory_read" })

    assert_equal ["own_tool"], declaration.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") }
    assert_equal ["nexus.memory.read"], declaration.fetch(:kernel_tools)
    assert_equal ["read"], declaration.fetch(:runner_tool_names)
    assert_equal ["runner-1"], declaration.fetch(:runner_executor_public_ids)
    assert_equal "custom/model", declaration.fetch(:default_model)
    assert_equal "dev/image", declaration.fetch(:image_model)
    assert_empty declaration.fetch(:fallback_models)
    assert_includes declaration.dig(:system_prompt, "content"), "Be concise"
    refute declaration.key?(:answering_user_public_id)
    assert_equal base.fetch(:approval_rules), declaration.fetch(:approval_rules)
  end

  def test_fallback_inheritance_preserves_order_without_inserting_the_default
    declaration = Rho::PresetExecution.declaration(preset: preset(model: "custom/model"), base: base)
    fields = Rho::PresetExecution.selection(body: {}, declaration: declaration)
    assert_equal "custom/model", fields.fetch(:model)
    assert_equal ["b/second", "c/third"], fields.fetch(:fallback_models)
    assert_equal "default", fields.dig(:model_selection, "source")

    overridden = Rho::PresetExecution.selection(body: { "fallback_models" => [] }, declaration: declaration)
    assert_empty overridden.fetch(:fallback_models)
  end

  def test_mcp_defaults_on_independently_of_ordinary_tool_selections_and_preserves_unavailable_exclusions
    ref = { "source" => "nexus", "connection_public_id" => SecureRandom.uuid_v7 }
    tool = { "name" => "search", "callable_name" => "work_search" }
    connection = { "ref" => ref, "available" => true, "tools" => [tool] }
    source = base.merge(mcp_directory: [connection], runner_executor_public_ids: [])
    selected = { "connection_public_id" => ref.fetch("connection_public_id"), "tool_name" => "search", "name" => "work_search" }

    declaration = Rho::PresetExecution.declaration(preset: preset(tools: [], runner_tool_names: []), base: source)

    assert_equal [selected], declaration.fetch(:mcp_tools)
    assert_empty declaration.fetch(:tool_definitions)
    assert_empty declaration.fetch(:kernel_tools)
    refute declaration.key?(:mcp_directory)
    disabled = preset(mcp: { "disabled_connections" => [ref], "disabled_tools" => [] })
    assert_empty Rho::PresetExecution.declaration(preset: disabled, base: source).fetch(:mcp_tools)
    assert_empty Rho::PresetExecution.declaration(preset: preset, base: source.merge(mcp_directory: [connection.merge("available" => false)])).fetch(:mcp_tools)
    assert_equal [ref], disabled.configuration.fetch("mcp").fetch("disabled_connections")
  end

  def test_equal_default_is_still_explicit_and_only_explicit_conversation_selections_persist
    declaration = Rho::PresetExecution.declaration(preset: preset, base: base)
    explicit = Rho::PresetExecution.selection(body: { "model" => "a/first" }, declaration: declaration)
    assert_equal "explicit", explicit.dig(:model_selection, "source")
    assert_equal "route", explicit.dig(:model_selection, "constraint")

    changed = declaration.merge(default_model: "new/default")
    assert_equal "a/first", Rho::PresetExecution.selection(body: {}, declaration: changed,
      prior: explicit.fetch(:model_selection)).fetch(:model)
    automatic = Rho::PresetExecution.selection(body: {}, declaration: declaration)
    assert_equal "new/default", Rho::PresetExecution.selection(body: {}, declaration: changed,
      prior: automatic.fetch(:model_selection)).fetch(:model)
  end

  def test_null_model_clears_a_previous_explicit_selection_and_follows_the_current_preset
    declaration = Rho::PresetExecution.declaration(preset: preset(model: "new/default"), base: base)
    prior = { "source" => "explicit", "model" => "a/first", "constraint" => "route", "alternatives" => [] }

    selected = Rho::PresetExecution.selection(body: { "model" => nil }, declaration: declaration, prior: prior)

    assert_equal "new/default", selected.fetch(:model)
    assert_equal({ "source" => "default", "model" => "new/default", "constraint" => "any", "alternatives" => [] },
      selected.fetch(:model_selection))
    assert_equal ["b/second", "c/third"], selected.fetch(:fallback_models)
  end

  def test_an_empty_selection_envelope_is_a_typed_preset_refusal
    declaration = Rho::PresetExecution.declaration(preset: preset, base: base)

    error = assert_raises(Rho::AgentPresets::Error) do
      Rho::PresetExecution.selection(body: { "model_selection" => {} }, declaration: declaration)
    end

    assert_equal "Select a default model or a model for this request", error.message
  end
end
