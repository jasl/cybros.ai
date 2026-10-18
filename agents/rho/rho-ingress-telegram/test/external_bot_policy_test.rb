require_relative "test_helper"
require "rho/bot_policy"

class TelegramExternalBotPolicyTest < Minitest::Test
  def test_external_bot_policy_keeps_its_floor_under_every_shipped_alias
    presets = CybrosAgent::ModelAdaptations.load.presets
    kernel_names = presets.plain.merge("nexus.memory.read" => "memory_read", "nexus.memory.write" => "memory_write",
      "nexus.runners.list" => "runners_list")
    presets.words.each do |style|
      aliases = presets.aliases_for([style])
      wires = kernel_names.merge(aliases.to_h { |entry| [entry.fetch("canonical"), entry.fetch("name")] })
      configuration = {
        tool_definitions: aliases.map { |entry| { "type" => "function", "function" => { "name" => entry.fetch("name") },
          "canonical" => entry.fetch("canonical") } } + [
          { "type" => "function", "function" => { "name" => "remote_read" },
            "route" => { "kind" => "runner", "runner_executor_public_id" => "remote", "tool_name" => "read" } },
          { "type" => "function", "function" => { "name" => "read" },
            "route" => { "kind" => "runner", "runner_executor_public_id" => "private", "tool_name" => "bash" } },
        ],
        kernel_tools: kernel_names.keys.reject { |canonical| CybrosAgent::ModelAdaptations::Styles.superseded?(canonical, [style], presets: presets) },
        runner_executor_public_ids: ["runner"], runner_tool_names: nil,
        approval_mode: "bypass", approval_rules: [{ "tool" => "*", "verdict" => "allow" }],
        prompt_template: nil, memory_context_limit: nil,
      }
      result = Rho::BotPolicy.external(configuration, send_targets: [], spawn_roles: [], wire_names: wires)
      assert_empty result.fetch(:runner_executor_public_ids), style
      assert_empty result.fetch(:runner_tool_names), style
      assert result.fetch(:tool_definitions).all? { |row| Rho::BotPolicy::KERNEL_TOOLS.include?(row.fetch("canonical")) }, style
      refute_includes result.fetch(:kernel_tools), "nexus.runners.list", style
      assert_equal "subtree", result.fetch(:conversation_reach), style
      assert_equal "rules", result.fetch(:approval_mode), style
      refute result.fetch(:approval_rules).any? { |rule| rule.fetch("tool") == "*" }, style
      granted = result.fetch(:approval_rules).flat_map { |rule| rule.fetch("tool").split("|") }
      Rho::BotPolicy::DELEGATION_TOOLS.each do |canonical|
        refute_includes granted, wires.fetch(canonical), "#{style}: an empty role/Bot directory grants no delegation"
      end
      assert_includes granted, "memory_read", style
      assert_includes granted, "memory_write", style
      assert_equal Rho::BotPolicy::MEMORY_CONTEXT_LIMIT, result.fetch(:memory_context_limit), style
      refute result.fetch(:prompt_template).fetch("blocks").any? { |block| block["slot"] == "persona" }, style
    end
  end

  def test_passive_participation_remains_toolless_and_does_not_extract_memory
    prompt = Rho::IngressTelegram::ParticipationWorkflow::PROMPT
    refute_includes prompt, Rho::MemoryPolicy::PROMPT
    assert_includes prompt, "No tools are available."
  end
end
