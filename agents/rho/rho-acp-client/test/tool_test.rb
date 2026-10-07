require "test_helper"

# THE TOOL CLASS: built at registration in rho-mcp's
# `Curation` shape, closing over the rows — NAME `delegate_agent`, the
# DESCRIPTION assembled from the rows' own `description` keys (no stored
# probe), the SCHEMA's `agent` the enabled keys, bash's effect profile,
# TIMEOUT_MS the longest enabled clock, INTERNAL_CLAMP.
class ToolTest < Minitest::Test
  Tool = Rho::AcpClient::Tool

  def rows
    Rho::AcpClient::Settings.parse({
      "opencode" => { "command" => "opencode", "args" => ["acp"], "description" => "OpenCode, a coding agent on OpenRouter",
                      "timeout_ms" => 600_000 },
      "codex" => { "command" => "npx", "args" => ["-y", "@agentclientprotocol/codex-acp@1.12.0"],
                   "description" => "Codex under the ChatGPT login", "timeout_ms" => 900_000 },
      "off" => { "command" => "x", "description" => "switched off", "enabled" => false, "timeout_ms" => 5_000_000 },
    })
  end

  def test_the_class_passes_the_runners_validation_and_carries_the_constants
    klass = Tool.build(rows)
    validator = Rho::Runner::Extensions::Tool.validate(klass, extension: "rho.acp-client")
    assert_nil Rho::Runner::InputSchema.refusal(validator, { "agent" => "codex", "prompt" => "hi" })
    assert_equal "delegate_agent", klass::NAME
    assert_equal Rho::Runner::Tools::Bash::EFFECT_PROFILE, klass::EFFECT_PROFILE
    assert_equal 900_000, klass::TIMEOUT_MS, "the longest ENABLED clock; the disabled row's never"
    assert klass::INTERNAL_CLAMP
    assert_equal "Rho::AcpClient::Tools[delegate_agent]", klass.name
    assert_equal klass.name, klass.inspect
    assert klass.method_defined?(:call)
  end

  def test_the_schema_offers_the_enabled_agents_and_the_four_parameters
    schema = Tool.build(rows)::SCHEMA
    assert_equal "object", schema.fetch("type")
    assert_equal %w[agent prompt session workdir], schema.fetch("properties").keys
    assert_equal %w[opencode codex], schema.dig("properties", "agent", "enum")
    assert_equal %w[agent prompt], schema.fetch("required")
    assert_predicate schema, :frozen?
    Rho::Runner::InputSchema.compile(schema)
  end

  # The description is the rows' words in a fixed frame — one line per
  # enabled agent, in settings order — and states the boundary.
  def test_the_description_is_assembled_from_the_rows_descriptions
    description = Tool.build(rows)::DESCRIPTION
    assert_includes description, "opencode: OpenCode, a coding agent on OpenRouter"
    assert_includes description, "codex: Codex under the ChatGPT login"
    refute_includes description, "switched off"
    assert_includes description, "runner"
    assert_predicate description, :frozen?
    assert_equal description, Tool.description(rows)
  end

  # THE CALL is the module's (`Rho::AcpClient.call`), handed the bound
  # environment: the class closes over nothing but the caller.
  def test_call_hands_the_arguments_and_the_env_to_the_caller
    seen = nil
    klass = Tool.build(rows, caller: ->(args, env:) { seen = [args, env]; :answered })
    env = Object.new
    assert_equal :answered, klass.new(env: env).call({ "agent" => "codex", "prompt" => "hi" })
    assert_equal [{ "agent" => "codex", "prompt" => "hi" }, env], seen
  end

  def test_no_enabled_row_builds_no_class
    assert_nil Tool.build(rows.select { |row| row.key == "off" })
    assert_nil Tool.build([])
  end
end
