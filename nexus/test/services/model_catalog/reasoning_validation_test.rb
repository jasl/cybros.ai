require "test_helper"
require "tmpdir"

class ModelCatalog::ReasoningValidationTest < ActiveSupport::TestCase
  test "reasoning declarations reject scalar and sequence shapes at the catalog boundary" do
    [false, "enabled", 1, [], [["default_enabled", true]]].each do |value|
      error = assert_raises(ModelCatalog::CompileError) { compile_reasoning(value) }
      assert_includes error.message, "reasoning must be a mapping"
    end
  end

  test "enablement defaults are model policy independent of wire vocabularies" do
    [true, false].each do |enabled|
      reasoning = { "default_enabled" => enabled, "disable_supported" => true }
      candidate = compile_reasoning(reasoning)
      entry = candidate.models.fetch("local/text")
      profile = ModelCatalog::ProfileBuilder.call(model_ref: "local/text",
        provider: candidate.providers.fetch("local"), model: entry)
      selected, refusal = Nexus::EffectiveReasoning.derive(entry.dig("capabilities", "reasoning"), nil)

      assert_nil refusal
      assert_equal enabled, selected.enabled
      assert_nil selected.effort
      assert_empty profile.reasoning_options, "a switch-only model declares no effort vocabulary"
    end
  end

  test "reasoning enablement declarations accept booleans only" do
    %w[default_enabled disable_supported].each do |key|
      [nil, "false", 0].each do |value|
        error = assert_raises(ModelCatalog::CompileError) { compile_reasoning({ key => value }) }
        assert_includes error.message, "#{key} must be boolean"
      end
    end
  end

  test "a disabled catalog default requires declared disable support" do
    [{}, { "disable_supported" => false }].each do |extra|
      error = assert_raises(ModelCatalog::CompileError) do
        compile_reasoning({ "default_enabled" => false }.merge(extra))
      end
      assert_includes error.message, "default_enabled false requires disable_supported true"
    end
  end

  test "none cannot enter the public effort vocabulary or become an effort default" do
    [
      { "efforts" => %w[none low], "default_effort" => "low" },
      { "efforts" => %w[low], "default_effort" => "none" },
    ].each do |reasoning|
      error = assert_raises(ModelCatalog::CompileError) { compile_reasoning(reasoning) }
      assert_includes error.message, "none"
    end
  end

  test "selector enablement and effort are independent and validated by the resolver derivation" do
    reasoning = { "efforts" => %w[low high], "default_effort" => "low", "disable_supported" => true }
    candidates = [
      { "model" => "local/text", "reasoning_enabled" => false, "reasoning_effort" => "high" },
      { "model" => "local/text", "reasoning_enabled" => true },
      { "model" => "local/text" },
    ]
    candidate = compile_reasoning(reasoning, candidates: candidates)

    assert_equal candidates, candidate.selectors.fetch("interactive")
    candidates.each do |choice|
      selected, refusal = Nexus::EffectiveReasoning.derive(reasoning,
        choice["reasoning_effort"], enabled: choice["reasoning_enabled"])
      assert_nil refusal
      assert_equal choice.fetch("reasoning_enabled", true), selected.enabled
    end
  end

  test "an unsupported selector off request compiles and resolves to enabled" do
    reasoning = { "efforts" => %w[low], "default_effort" => "low" }
    choice = { "model" => "local/text", "reasoning_enabled" => false }
    candidate = compile_reasoning(reasoning, candidates: [choice])
    selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil, enabled: false)

    assert_equal [choice], candidate.selectors.fetch("interactive")
    assert_nil refusal
    assert_equal true, selected.enabled
  end

  test "selector enablement rejects null and boolean lookalikes" do
    [nil, "false", 0].each do |value|
      error = assert_raises(ModelCatalog::CompileError) do
        compile_reasoning({ "default_enabled" => true },
          candidates: [{ "model" => "local/text", "reasoning_enabled" => value }])
      end
      assert_includes error.message, "reasoning_enabled must be boolean"
    end
  end

  private

    def compile_reasoning(reasoning, candidates: [])
      Dir.mktmpdir do |root|
        File.write(File.join(root, "models.yml"), {
          "schema_version" => ModelCatalog::FileBase::SCHEMA_VERSION,
          "providers" => { "local" => {
            "api_format" => "openai_compatible_chat", "base_url" => "http://localhost:8080/v1",
            "credentials" => "none", "concurrency_limit" => 1,
          } },
          "models" => { "local/text" => { "reasoning" => reasoning } },
          "selectors" => candidates.empty? ? {} : { "interactive" => candidates },
        }.to_yaml)
        ModelCatalog::FileBase.compile(root: root, override_dir: nil)
      end
    end
end
