require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../../script/import_pi_catalog"

class PiCatalogImportTest < Minitest::Test
  def test_same_model_at_different_providers_keeps_independent_limits_and_wire
    first = model("first", "shared", contextWindow: 32_000, maxTokens: 4000,
      compat: { "thinkingFormat" => "zai", "supportsReasoningEffort" => false })
    second = model("second", "shared", contextWindow: 200_000, maxTokens: 16_000,
      compat: { "thinkingFormat" => "qwen", "supportsDeveloperRole" => true })
    importer = importer_for(first, second)
    fragments = importer.fragments
    a = fragments.fetch("first").fetch("models").fetch("first/shared")
    b = fragments.fetch("second").fetch("models").fetch("second/shared")
    assert_equal 32_000, a.dig("capabilities", "limits", "combined_input_output_tokens")
    assert_equal 200_000, b.dig("capabilities", "limits", "combined_input_output_tokens")
    assert_equal "zai", a.dig("wire_options", "reasoning_control")
    assert_equal "enable_thinking", b.dig("wire_options", "reasoning_control")
  end

  def test_existing_provider_owns_its_entire_model_set_including_omissions
    providers = { "openrouter" => { "api_format" => "openrouter_chat", "base_url" => "https://own.example",
      "wire_options" => { "stream_include_usage" => false } } }
    old = model("openrouter", "existing")
    added = model("openrouter", "new", api: "anthropic-messages", baseUrl: "https://pi.example",
      compat: { "allowEmptySignature" => true }, headers: { "User-Agent" => "source-identity" })
    before = Marshal.dump(providers)
    importer = importer_for(old, added, providers: providers)
    assert_empty importer.fragments
    assert_equal({ "openrouter" => 2 }, importer.report.fetch("excluded_existing_providers"))
    assert_equal before, Marshal.dump(providers)
  end

  def test_all_authored_providers_and_aliases_are_excluded_before_interpreting_pi_metadata
    source_ids = %w[openai anthropic google openai-codex openrouter deepseek xai]
    providers = %w[openai_api anthropic gemini codex_subscription openrouter deepseek xai].to_h { |id| [id, {}] }
    rows = source_ids.map do |id|
      { "provider" => id, "type" => "chat", "id" => "unowned", "api" => "unsupported-pi-api" }
    end
    importer = importer_for(*rows, providers: providers)
    assert_empty importer.fragments
    assert_equal providers.transform_values { 1 }, importer.report.fetch("excluded_existing_providers")
    assert_empty importer.report.fetch("pending_apis")
    assert_empty importer.report.fetch("unpriced")
  end

  def test_existing_provider_replacements_do_not_resurrect_retired_models
    providers = %w[openai_api codex_subscription gemini].to_h { |id| [id, {}] }
    importer = importer_for(model("openai", "gpt-6-sol", api: "openai-responses"),
      model("openai-codex", "gpt-6-sol", api: "openai-codex-responses"),
      model("google", "gemini-3.7-flash", api: "google-generative-ai"), providers: providers)
    assert_empty importer.fragments
    assert_equal providers.transform_values { 1 }, importer.report.fetch("excluded_existing_providers")
  end

  def test_cli_rejects_stale_fragments_and_regeneration_removes_only_generated_files
    Dir.mktmpdir("pi-catalog-import") do |root|
      authored = YAML.dump({ "providers" => { "openrouter" => { "api_format" => "openrouter_chat" } },
        "models" => { "openrouter/owned" => { "display_name" => "Owned model" } } })
      authored_path = File.join(root, "50_openrouter.yml")
      stale_path = File.join(root, "80_pi_openrouter.yml")
      source_path = File.join(root, "source.json")
      File.write(authored_path, authored)
      File.write(stale_path, "stale generated content\n")
      File.write(source_path, JSON.generate(source_for(model("openrouter", "unowned"), model("new-provider", "added"))))
      command = [RbConfig.ruby, File.expand_path("../../script/import_pi_catalog.rb", __dir__),
        "--source-json", source_path, "--catalog-root", root]

      output, status = Open3.capture2e(*command, "--check")
      refute status.success?, output
      assert_includes output, "unexpected generated catalog files: 80_pi_openrouter.yml"
      assert_equal "stale generated content\n", File.read(stale_path)
      assert_equal authored, File.read(authored_path)

      output, status = Open3.capture2e(*command)
      assert status.success?, output
      refute File.exist?(stale_path)
      assert_equal authored, File.read(authored_path)
      generated = YAML.safe_load_file(File.join(root, "80_pi_new-provider.yml"))
      assert_equal ["new-provider/added"], generated.fetch("models").keys
      report = JSON.parse(File.read(File.join(root, "pi_import_report.json")))
      assert_equal({ "openrouter" => 1 }, report.fetch("excluded_existing_providers"))
      assert_equal 1, report.fetch("imported_providers")
      assert_equal 1, report.fetch("imported_models")

      output, status = Open3.capture2e(*command, "--check")
      assert status.success?, output
    end
  end

  def test_new_provider_preserves_its_own_budget_endpoint_and_noncredential_headers
    added = model("gateway", "old", api: "anthropic-messages", baseUrl: "https://gateway.example/{account}",
      headers: { "User-Agent" => "GatewayClient" }, compat: { "allowEmptySignature" => true })
    fragment = importer_for(added).fragments.fetch("gateway")
    assert_nil fragment.dig("providers", "gateway", "base_url")
    row = fragment.fetch("models").fetch("gateway/old")
    assert_equal "budget", row.dig("wire_options", "anthropic_thinking_control")
    assert_equal true, row.dig("wire_options", "allow_empty_thinking_signature")
    assert_equal 2048, row.dig("wire_options", "thinking_budgets", "low")
    assert_equal "GatewayClient", row.dig("request_headers", "User-Agent")
  end

  def test_unknown_or_inexpressible_prices_are_not_imported_as_free_or_rounded
    unknown = model("p", "unknown", cost: { "input" => -1, "output" => -1, "cacheRead" => 0, "cacheWrite" => 0 })
    repeating = model("p", "tier", cost: { "input" => 3, "output" => 2, "cacheRead" => 0, "cacheWrite" => 0,
      "tiers" => [{ "inputTokensAbove" => 1000, "input" => 4, "output" => 2, "cacheRead" => 0, "cacheWrite" => 0 }] })
    importer = importer_for(unknown, repeating)
    rows = importer.fragments.fetch("p").fetch("models")
    rows.each_value { |row| refute_includes row, "pricing" }
    assert_equal %w[p/tier p/unknown], importer.report.fetch("unpriced")
  end

  def test_native_bedrock_and_pi_routes_are_resolved_to_explicit_wire_facts
    bedrock = model("amazon-bedrock", "us.anthropic.claude-opus-5", api: "bedrock-converse-stream",
      baseUrl: "https://bedrock-runtime.us-east-1.amazonaws.com", thinkingLevelMap: { "max" => "max" })
    radius = model("radius", "balanced", api: "pi-messages", baseUrl: "https://radius.pi.dev/v1")
    fragments = importer_for(bedrock, radius).fragments
    row = fragments.fetch("amazon-bedrock").fetch("models").values.first
    assert_equal "bedrock_converse", row.fetch("api_format")
    assert_equal "adaptive", row.dig("wire_options", "bedrock_thinking_control")
    assert_equal "drop_block", row.dig("wire_options", "thinking_binding")
    assert_equal "low", row.dig("wire_options", "reasoning_effort_map", "minimal")
    assert_equal "max", row.dig("wire_options", "reasoning_effort_map", "max")
    assert_equal 16_000, row.dig("capabilities", "generation_parameters", "max_output_tokens", "default")
    row = fragments.fetch("radius").fetch("models").values.first
    assert_equal "/v1/messages", row.dig("wire_options", "messages_path")
    assert_equal "pi_thinking", row.dig("capabilities", "reasoning_replay", "format")
  end

  def test_declared_thinking_controls_match_the_selected_provider_wire
    rows = [
      model("amazon-bedrock", "amazon.nova-2-lite", api: "bedrock-converse-stream"),
      model("switch", "m", compat: { "supportsReasoningEffort" => false, "thinkingFormat" => "together" }),
      model("silent", "m", compat: { "supportsReasoningEffort" => false }),
      model("github-copilot", "gpt", api: "openai-responses", thinkingLevelMap: { "minimal" => "low" }),
      model("azure", "deepseek-v4-pro", baseUrl: "", compat: { "thinkingFormat" => "deepseek" }),
    ]
    fragments = importer_for(*rows).fragments
    %w[amazon-bedrock switch silent].each do |provider|
      reasoning = fragments.fetch(provider).fetch("models").values.first.dig("capabilities", "reasoning")
      refute_includes reasoning, "efforts"
      refute_includes reasoning, "default_effort"
      assert_equal provider == "switch", reasoning.fetch("disable_supported")
    end
    copilot = fragments.fetch("github-copilot").fetch("models").values.first
    refute_includes copilot.dig("capabilities", "reasoning", "efforts"), "minimal"
    azure = fragments.fetch("azure").fetch("models").values.first
    assert_equal "/openai/v1/chat/completions", azure.dig("wire_options", "chat_path")
  end

  private

  def model(provider, id, **overrides)
    { "provider" => provider, "id" => id, "name" => id, "type" => "chat",
      "api" => "openai-completions", "baseUrl" => "https://#{provider}.example/v1", "reasoning" => true,
      "input" => ["text"], "contextWindow" => 100_000, "maxTokens" => 16_000,
      "cost" => { "input" => 1, "output" => 2, "cacheRead" => 0.1, "cacheWrite" => 0 } }.merge(overrides.transform_keys(&:to_s))
  end

  def importer_for(*rows, providers: {})
    PiCatalogImport.new(source: source_for(*rows), existing_providers: providers)
  end

  def source_for(*rows)
    source = { ".manifest" => { "generatedAt" => "2026-10-07T22:01:28.515Z" } }
    rows.each do |row|
      ((source[row.fetch("provider")] ||= {})[row.fetch("api")] ||= {})["chat:#{row.fetch("id")}"] = row
    end
    source
  end
end
