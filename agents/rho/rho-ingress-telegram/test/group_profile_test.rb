require_relative "test_helper"

class TelegramGroupProfileTest < Minitest::Test
  def test_profile_omits_personal_slots_and_limits_tools_under_every_shipped_alias
    registered = []
    api = Object.new
    api.define_singleton_method(:register_agent) { |definition| registered << definition }
    Rho::IngressTelegram::GroupProfile.register(api)
    definition = registered.fetch(0)
    refute_includes definition.body, "{{conversation_kind}}", "the system slot is shared with a side"
    presets = CybrosAgent::ModelAdaptations.load.presets
    aliases = presets.aliases_for(presets.words)
    names = presets.plain.values + aliases.map { |row| row.fetch("name") } + %w[memory_read memory_write session_search session_read bash read image_generate imagegen]
    parent = { tool_definitions: names.map { |name| { "type" => "function", "function" => { "name" => name } } },
      approval_mode: "ask", approval_rules: nil, compaction_policy: { "mode" => "kernel" }, fallback_model: nil }
    derived = Rho::LoopRequest.derived_declaration(parent, definition)
    allowed = derived.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") }
    canonical = allowed.filter_map { |name| presets.canonical_of(name) || aliases.find { |row| row["name"] == name }&.fetch("canonical") }

    assert_equal %w[nexus.graph.compose nexus.graph.task nexus.graph.wait nexus.human.ask], canonical.uniq.sort
    assert_includes allowed, "bash"
    assert_includes allowed, "image_generate"
    assert_includes allowed, "imagegen"
    assert_includes allowed, "memory_read"
    assert_includes allowed, "memory_write"
    refute (allowed & %w[skill Skill session_search session_read spawn spawn_agent send send_message]).any?
    assert_equal "assembly", derived.fetch(:prompt_mechanism)
    blocks = derived.fetch(:prompt_template).fetch("blocks")
    assert_equal ["system_prompt"], blocks.filter_map { |block| block["slot"] }
    assert_equal %w[slot memory history lead tail inline input], blocks.map { |block| block.fetch("type") }
    assert_equal({ "type" => "inline", "role" => "user", "text" => "Conversation kind: {{conversation_kind}}." },
      blocks.fetch(-2), "the group and its side each receive their own kind behind inherited history")
    assert_equal "ask", derived.fetch(:approval_mode), "the normal effect-approval policy still applies"
    assert_includes definition.body, Rho::MemoryPolicy::PROMPT
    assert_includes definition.body, Rho::ExecutionPolicy::PROMPT
    refute_includes definition.body, Rho::LoopRequest::GUIDELINE,
      "the named Telegram profile carries its own context and permission policy"
    assert_includes definition.body, "do not copy private-chat notes into group memory"
    refute_includes Rho::IngressTelegram::ParticipationWorkflow::PROMPT, Rho::MemoryPolicy::PROMPT,
      "passive group participation does not become a memory extraction turn"
    assert_includes Rho::IngressTelegram::ParticipationWorkflow::PROMPT, "No tools are available."
  end
end
