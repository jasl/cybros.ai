require_relative "test_helper"

class TelegramGroupProfileTest < Minitest::Test
  def test_read_only_selection_uses_each_runner_routes_served_name_and_preserves_the_callable
    definitions = [
      { "type" => "function", "function" => { "name" => "project_read__remote" },
        "route" => { "kind" => "runner", "runner_executor_public_id" => "remote", "tool_name" => "read" } },
      { "type" => "function", "function" => { "name" => "read" },
        "route" => { "kind" => "runner", "runner_executor_public_id" => "other", "tool_name" => "bash" } },
      { "type" => "function", "function" => { "name" => "Agent" }, "canonical" => "nexus.graph.delegate_task" },
    ]

    assert_equal %w[project_read__remote Agent], Rho::IngressTelegram::GroupProfile.read_only_names(definitions)
  end

  def test_profile_omits_personal_slots_and_limits_tools_under_every_shipped_alias
    registered = []
    api = Object.new
    api.define_singleton_method(:register_agent) { |definition| registered << definition }
    Rho::IngressTelegram::GroupProfile.register(api)
    definition = registered.fetch(0)
    refute_includes definition.body, "{{conversation_kind}}", "conversation metadata belongs in the per-request template"
    presets = CybrosAgent::ModelAdaptations.load.presets
    kernel_names = presets.plain.merge("nexus.memory.read" => "memory_read", "nexus.memory.write" => "memory_write")
    runner_names = %w[code session_search session_read bash read image_generate imagegen]
    presets.words.each do |style|
      aliases = presets.aliases_for([style])
      parent = { tool_definitions: aliases.map { |entry| { "type" => "function", "function" => { "name" => entry.fetch("name") },
        "canonical" => entry.fetch("canonical") } }, kernel_tools: kernel_names.keys.reject { |canonical|
          CybrosAgent::ModelAdaptations::Styles.superseded?(canonical, [style], presets: presets)
        }, runner_executor_public_ids: ["runner"], runner_tool_names: nil,
        approval_mode: "ask", approval_rules: nil, compaction_policy: { "mode" => "kernel" }, fallback_model: nil }
      derived = Rho::RunDeclaration.derived_declaration(parent, definition, kernel_tool_names: kernel_names, runner_names: runner_names)
      allowed = derived.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") } +
        derived.fetch(:kernel_tools).map { |name| kernel_names.fetch(name) } + derived.fetch(:runner_tool_names)
      canonical = allowed.filter_map { |name| presets.canonical_of(name) || aliases.find { |row| row["name"] == name }&.fetch("canonical") }

      expected_kernel = %w[nexus.graph.delegate_task nexus.graph.wait]
      expected_kernel << "nexus.human.ask" unless style == "codex"
      assert_equal expected_kernel, canonical.uniq.sort, style
      assert_includes allowed, "code"
      assert_includes allowed, "bash"
      assert_includes allowed, "image_generate"
      assert_includes allowed, "imagegen"
      assert_includes allowed, "memory_read"
      assert_includes allowed, "memory_write"
      assert_empty derived.fetch(:runner_tool_names) & (presets.plain.values + presets.owners.keys), style
      assert_equal ["runner"], derived.fetch(:runner_executor_public_ids)
      assert derived.fetch(:tool_definitions).all? { |entry| entry.key?("canonical") }, "Runner schemas remain Nexus's to assemble"
      refute (allowed & %w[skill Skill session_search session_read spawn spawn_agent send send_message]).any?
      assert_equal "assembly", derived.fetch(:prompt_mechanism)
      blocks = derived.fetch(:prompt_template).fetch("blocks")
      assert_equal ["system_prompt"], blocks.filter_map { |block| block["slot"] }
      assert_equal %w[slot memory history lead tail inline input], blocks.map { |block| block.fetch("type") }
      assert_equal({ "type" => "inline", "role" => "user", "text" => "Conversation kind: {{conversation_kind}}." },
        blocks.fetch(-2), "conversation metadata follows its retained history")
      assert_equal "ask", derived.fetch(:approval_mode), "the normal effect-approval policy still applies"
    end
    assert_includes definition.body, Rho::MemoryPolicy::PROMPT
    assert_includes definition.body, Rho::ExecutionPolicy::PROMPT
    refute_includes definition.body, Rho::RunDeclaration::GUIDELINE,
      "the named Telegram profile carries its own context and permission policy"
    assert_includes definition.body, "do not copy private-chat notes into group memory"
    refute_includes Rho::IngressTelegram::ParticipationWorkflow::PROMPT, Rho::MemoryPolicy::PROMPT,
      "passive group participation does not become a memory extraction turn"
    assert_includes Rho::IngressTelegram::ParticipationWorkflow::PROMPT, "No tools are available."
  end
end
