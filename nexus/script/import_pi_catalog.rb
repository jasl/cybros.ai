#!/usr/bin/env ruby
# Import a pinned public data artifact into Nexus's existing catalog grammar.
# Pi is a generation-time source; Nexus never loads or calls Pi at runtime.
require "base64"
require "bigdecimal"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "optparse"
require "rubygems/package"
require "stringio"
require "yaml"
require "zlib"
require_relative "../vendor/simple_inference/lib/simple_inference"

class PiCatalogImport
  VERSION = "1.1.0".freeze
  SOURCE_REVISION = "6fb2e7815167e6b19006fc526d1a5d0f5f998787".freeze
  TARBALL = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-#{VERSION}.tgz".freeze
  INTEGRITY = "1T7LAkc/5Bvc0v6w4vAGVdCrli0o/E0pEmYKTnixu95vSFArBjvbhS/G4ZwI0RUePgf0Imcu0VyqlM4EcXxqfw==".freeze
  ALIASES = { "openai" => "openai_api", "google" => "gemini", "openai-codex" => "codex_subscription" }.freeze
  FORMATS = {
    "openai-responses" => "openai_responses", "azure-openai-responses" => "openai_responses",
    "openai-completions" => "openai_compatible_chat",
    "anthropic-messages" => "anthropic_messages", "google-generative-ai" => "gemini_generate_content",
    "google-vertex" => "gemini_generate_content", "mistral-conversations" => "mistral_chat",
    "bedrock-converse-stream" => "bedrock_converse", "pi-messages" => "pi_messages",
  }.freeze
  THINKING_CONTROLS = {
    "openai" => "reasoning_effort", "deepseek" => "deepseek", "zai" => "zai",
    "together" => "together", "qwen" => "enable_thinking", "baseten" => "chat_template_args",
    "ant-ling" => "nested_effort", "openrouter" => "nested_effort",
  }.freeze
  REPLAY_FORMATS = {
    "anthropic_messages" => "anthropic_thinking", "gemini_generate_content" => "gemini_thought",
    "openai_responses" => "responses_reasoning", "openai_compatible_chat" => "chat_reasoning",
    "mistral_chat" => "chat_reasoning",
    "bedrock_converse" => "bedrock_reasoning", "pi_messages" => "pi_thinking",
  }.freeze
  LEVELS = %w[minimal low medium high xhigh max].freeze
  ANTHROPIC_BUDGETS = { "minimal" => 1024, "low" => 2048, "medium" => 8192, "high" => 16384,
                       "xhigh" => 16384, "max" => 16384 }.freeze

  def self.download
    response = Net::HTTP.get_response(URI(TARBALL))
    raise "Pi artifact download failed: HTTP #{response.code}" unless response.code == "200"
    bytes = response.body
    raise "Pi artifact integrity mismatch" unless Base64.strict_encode64(Digest::SHA512.digest(bytes)) == INTEGRITY

    data = {}
    archive = Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(bytes)))
    archive.each do |entry|
      next unless entry.file? && entry.full_name.match?(%r{/providers/data/[^/]+\.json\z})

      data[File.basename(entry.full_name, ".json")] = JSON.parse(entry.read)
    end
    data
  end

  attr_reader :report

  def initialize(source:, existing_providers:)
    @source, @existing_providers = source, existing_providers
    @report = {
      "artifact" => "@earendil-works/pi-ai@#{VERSION}", "artifact_integrity" => "sha512-#{INTEGRITY}",
      "adapter_source_revision" => SOURCE_REVISION, "generated_at" => source.fetch(".manifest").fetch("generatedAt"),
      "scope" => "new providers only; chat models; API-key credential lane; offline source fixtures",
      "excluded_existing_providers" => {}, "pending_apis" => {}, "unpriced" => [],
    }
  end

  def fragments
    rows = @source.reject { |provider, _| provider.start_with?(".") }.values
      .flat_map { |apis| apis.values.flat_map(&:values) }.select { |model| model.fetch("type") == "chat" }
    @report["source_chat_pairs"] = rows.length
    @report["source_chat_providers"] = rows.map { |model| model.fetch("provider") }.uniq.length
    results = rows.group_by { |model| model.fetch("provider") }.sort.to_h do |source_provider, models|
      provider_id = ALIASES.fetch(source_provider, source_provider)
      # An authored provider owns its entire model set, including omissions.
      # Skip it before interpreting any Pi model metadata or compatibility facts.
      if @existing_providers.key?(provider_id)
        @report.fetch("excluded_existing_providers")[provider_id] = models.length
        next [provider_id, nil]
      end
      supported = models.select do |model|
        supported = FORMATS.key?(model.fetch("api"))
        unless supported
          (@report["pending_apis"][model.fetch("api")] ||= []) << "#{provider_id}/#{model.fetch("id")}"
        end
        supported
      end
      next [provider_id, nil] if supported.empty?

      provider = provider_definition(source_provider, supported)
      entries = supported.sort_by { |model| model.fetch("id") }.to_h do |model|
        ref = "#{provider_id}/#{model.fetch("id")}"
        [ref, model_definition(model, provider, ref)]
      end
      [provider_id, { "schema_version" => "cybros.model_catalog.v1",
        "providers" => { provider_id => provider }, "models" => entries }]
    end.compact
    @report["imported_models"] = results.values.sum { |fragment| fragment.fetch("models").length }
    @report["imported_providers"] = results.values.sum { |fragment| fragment.fetch("providers").length }
    results
  end

  private

  def format(model) = FORMATS.fetch(model.fetch("api"))

  def provider_definition(id, models)
    first = models.first
    definition = { "api_format" => format(first), "base_url" => endpoint(first), "concurrency_limit" => 2 }
    definition["authentication"] = "cf-aig-authorization" if id == "cloudflare-ai-gateway"
    definition["authentication"] = "api-key" if id == "azure"
    definition["authentication"] = "bearer" if id == "github-copilot"
    definition
  end

  def endpoint(model)
    url = model.fetch("baseUrl")
    return nil if url.empty? || url.include?("{")
    url.sub(%r{/v1(?:beta)?\z}, "")
  end

  def model_definition(model, provider, ref)
    wire = wire_options(model)
    caps = {
      "input_modalities" => model.fetch("input") - ["text"],
      "limits" => limits(model),
      "generation_parameters" => { "max_output_tokens" => { "maximum" => model.fetch("maxTokens") } },
    }
    unless SimpleInference::ApiFormat.protocol_class(format(model)).request_option_keys.include?(:max_output_tokens)
      caps.fetch("generation_parameters").delete("max_output_tokens")
    end
    # Messages requires max_tokens even when the caller leaves output size unset.
    if format(model) == "anthropic_messages" || (format(model) == "bedrock_converse" && bedrock_claude?(model))
      caps.fetch("generation_parameters").fetch("max_output_tokens")["default"] = model.fetch("maxTokens")
    end
    if model.fetch("reasoning")
      caps["reasoning"] = reasoning(model)
      caps["reasoning_replay"] = { "format" => REPLAY_FORMATS.fetch(format(model)) }
      if wire["requires_reasoning_content"]
        caps.fetch("reasoning_replay")["required_for_tool_rounds"] = true
      end
    end
    definition = { "display_name" => model.fetch("name"), "api_format" => format(model),
      "capabilities" => caps, "wire_options" => wire }
    definition["request_headers"] = model.fetch("headers") if model.key?("headers")
    model_endpoint = endpoint(model)
    definition["base_url"] = model_endpoint unless model_endpoint == provider.fetch("base_url")
    prices = pricing(model)
    prices ? definition["pricing"] = prices : @report.fetch("unpriced") << ref
    definition
  end

  def limits(model)
    { "output_tokens" => model.fetch("maxTokens"), "combined_input_output_tokens" => model.fetch("contextWindow") }
  end

  def reasoning(model)
    mapping = model.fetch("thinkingLevelMap", {})
    wire = wire_options(model)
    if wire["bedrock_thinking_control"] == "none"
      return { "default_enabled" => true, "disable_supported" => false }
    end
    if format(model) == "openai_compatible_chat" && wire["supports_reasoning_effort"] == false &&
        !%w[nested_effort string_thinking].include?(wire["reasoning_control"])
      return { "default_enabled" => true,
        "disable_supported" => wire["reasoning_control"] != "reasoning_effort" && mapping.fetch("off", "off") != nil }
    end
    efforts = LEVELS.select do |level|
      !mapping.key?(level) || !mapping.fetch(level).nil?
    end
    efforts -= %w[xhigh max].reject { |level| mapping.key?(level) }
    case format(model)
    when "anthropic_messages"
      # Pi maps minimal to low on adaptive Messages, which has no minimal word.
      efforts -= ["minimal"] if model.dig("compat", "forceAdaptiveThinking")
    when "gemini_generate_content"
      efforts &= %w[minimal low medium high]
    when "openai_responses"
      # The Responses adapter takes native effort words. Pi's minimal->low
      # aliases on routed models are not an additional upstream capability.
      efforts -= mapping.filter_map { |level, value| level if value && value != level }
    else nil
    end
    result = { "efforts" => efforts, "default_effort" => efforts.include?("high") ? "high" : efforts.last,
      "default_enabled" => true, "disable_supported" => mapping.fetch("off", "off") != nil }
    result["disable_supported"] = false if format(model) == "gemini_generate_content" && google_level?(model)
    result.compact
  end

  def wire_options(model)
    compat = model.fetch("compat", {})
    case format(model)
    when "openai_compatible_chat", "mistral_chat" then chat_options(model)
    when "anthropic_messages"
      options = { "allow_empty_thinking_signature" => compat.fetch("allowEmptySignature", false),
        "mid_conversation_system" => compat.fetch("supportsMidConvoSystemMessages", false),
        "thinking_omits_temperature" => true }
      if model.fetch("reasoning")
        adaptive = compat.fetch("forceAdaptiveThinking", false)
        options["anthropic_thinking_control"] = adaptive ? "adaptive" : "budget"
        options["thinking_budgets"] = ANTHROPIC_BUDGETS unless adaptive
      end
      options["messages_path"] = "/anthropic/v1/messages" if model.fetch("provider") == "cloudflare-ai-gateway"
      options
    when "gemini_generate_content"
      options = { "models_path" => model.fetch("api") == "google-vertex" ?
        "/v1/publishers/google/models" : "#{URI(model.fetch("baseUrl")).path}/models" }
      if model.fetch("reasoning") && !google_level?(model)
        options["gemini_thinking_control"] = "budget"
        options["thinking_budgets"] = google_budgets(model)
      end
      options
    when "openai_responses"
      if model.fetch("provider") == "cloudflare-ai-gateway"
        { "responses_path" => "/openai/responses" }
      elsif model.fetch("api") == "azure-openai-responses"
        { "responses_path" => "/openai/v1/responses?api-version=v1" }
      else {}
      end
    when "bedrock_converse" then bedrock_options(model)
    when "pi_messages" then { "messages_path" => "#{URI(model.fetch("baseUrl")).path}/messages" }
    else {}
    end
  end

  def bedrock_claude?(model)
    [model.fetch("id"), model.fetch("name")].any? { |value| value.downcase.include?("claude") }
  end

  # Pi's model-name routing is resolved once while generating metadata. The
  # runtime adapter receives these explicit facts and never guesses a family.
  def bedrock_options(model)
    return {} unless model.fetch("reasoning")

    candidates = [model.fetch("id"), model.fetch("name")].map { |value| value.downcase.gsub(/[\s_.:]+/, "-") }
    if bedrock_claude?(model)
      modern = candidates.any? { |value| value.match?(/(?:opus-4-[78]|opus-5|sonnet-5|haiku-5|fable-5)/) }
      adaptive = modern || candidates.any? { |value| value.match?(/(?:opus|sonnet)-4-6/) }
      govcloud = model.fetch("id").start_with?("us-gov.", "arn:aws-us-gov:")
      options = { "bedrock_thinking_control" => adaptive ? "adaptive" : "budget",
        "thinking_omits_temperature" => true, "bedrock_omit_thinking_display" => govcloud }
      if adaptive
        options["reasoning_effort_map"] = { "minimal" => "low", "xhigh" => modern ? "xhigh" : "high", "max" => "high" }
          .merge(model.fetch("thinkingLevelMap", {}))
        options["thinking_binding"] = "drop_block" if modern && !govcloud
      else
        options["thinking_budgets"] = ANTHROPIC_BUDGETS
      end
      options
    elsif candidates.any? { |value| value.include?("gpt-oss") }
      { "bedrock_thinking_control" => "reasoning_effort",
        "reasoning_effort_map" => { "minimal" => "low", "xhigh" => "high", "max" => "high" } }
    elsif candidates.any? { |value| value.include?("gpt-") }
      { "bedrock_thinking_control" => "nested_effort",
        "reasoning_effort_map" => { "minimal" => "low" }.merge(model.fetch("thinkingLevelMap", {})) }
    else
      { "bedrock_thinking_control" => "none" }
    end
  end

  def google_level?(model)
    id = model.fetch("id").downcase
    id.match?(/gemini-3(?:\.\d+)?-(?:pro|flash)|gemma-?4/) || %w[gemini-flash-latest gemini-flash-lite-latest].include?(id)
  end

  def google_budgets(model)
    id = model.fetch("id")
    return %w[minimal low medium high].to_h { |level| [level, -1] } unless id.include?("2.5-")

    { "minimal" => id.include?("flash-lite") ? 512 : 128, "low" => 2048, "medium" => 8192,
      "high" => id.include?("2.5-pro") ? 32768 : 24576 }
  end

  def chat_options(model)
    return { "stream_include_usage" => false } if format(model) == "mistral_chat"

    id = model.fetch("provider")
    compat = model.fetch("compat", {})
    nonstandard = %w[nvidia cerebras xai together deepseek zai zai-coding-cn moonshotai moonshotai-cn
      opencode opencode-go cloudflare-workers-ai cloudflare-ai-gateway ant-ling].include?(id)
    max_tokens = %w[deepseek moonshotai moonshotai-cn cloudflare-ai-gateway together nvidia ant-ling zai zai-coding-cn].include?(id)
    effort = !%w[xai zai zai-coding-cn moonshotai moonshotai-cn together cloudflare-ai-gateway nvidia ant-ling].include?(id)
    options = {
      "max_tokens_field" => compat.fetch("maxTokensField", max_tokens ? "max_tokens" : "max_completion_tokens"),
      "supports_developer_role" => compat.fetch("supportsDeveloperRole", !nonstandard && id != "openrouter"),
      "supports_strict_tools" => compat.fetch("supportsStrictMode", false),
      "requires_reasoning_content" => compat.fetch("requiresReasoningContentOnAssistantMessages", id == "deepseek"),
      "supports_reasoning_effort" => compat.fetch("supportsReasoningEffort", effort),
      "stream_include_usage" => compat.fetch("supportsUsageInStreaming", true),
    }
    options["tool_stream"] = true if compat["zaiToolStream"]
    if format(model) == "openai_compatible_chat" && model.fetch("reasoning")
      default = case id
      when "deepseek" then "deepseek"
      when "zai", "zai-coding-cn" then "zai"
      when "together" then "together"
      when "ant-ling" then "ant-ling"
      else "openai"
      end
      options["reasoning_control"] = THINKING_CONTROLS.fetch(compat.fetch("thinkingFormat", default))
      options["reasoning_effort_map"] = model.fetch("thinkingLevelMap") if model.key?("thinkingLevelMap")
    end
    # These APIs' path versions are not /v1. The source endpoint is retained.
    options["chat_path"] = "/chat/completions" if %w[zai zai-coding-cn].include?(id)
    options["chat_path"] = "/compat/chat/completions" if id == "cloudflare-ai-gateway"
    options["chat_path"] = "/openai/v1/chat/completions" if id == "azure"
    options
  end

  # Flat rates and exactly representable one-threshold schedules only. A
  # richer/unknown schedule stays unpriced instead of silently underbilling.
  def pricing(model)
    cost = model.fetch("cost")
    return nil if cost.values_at("input", "output").all?(&:zero?)
    tiers = cost.fetch("tiers", [])
    return nil if tiers.length > 1

    rates = { "input_per_mtok" => decimal(cost.fetch("input")), "output_per_mtok" => decimal(cost.fetch("output")),
      "cached_input_per_mtok" => decimal(cost.fetch("cacheRead")), "cache_write_per_mtok" => decimal(cost.fetch("cacheWrite")) }
    return nil unless rates.values.all? { |rate| rate.match?(/\A\d+(?:\.\d{1,12})?\z/) }
    if tiers.one?
      tier = tiers.first
      return nil if cost.fetch("input").zero? || cost.fetch("output").zero?
      input_ratio = BigDecimal(tier.fetch("input").to_s) / BigDecimal(cost.fetch("input").to_s)
      output_ratio = BigDecimal(tier.fetch("output").to_s) / BigDecimal(cost.fetch("output").to_s)
      return nil unless [input_ratio, output_ratio].all? { |ratio| ratio.to_s("F").match?(/\A\d+(?:\.\d{1,12})?\z/) }
      return nil unless %w[cacheRead cacheWrite].all? do |key|
        BigDecimal(tier.fetch(key).to_s) == BigDecimal(cost.fetch(key).to_s) * input_ratio
      end
      rates.merge!("long_context_threshold_tokens" => tier.fetch("inputTokensAbove").to_s,
        "long_context_input_multiplier" => input_ratio.to_s("F"), "long_context_output_multiplier" => output_ratio.to_s("F"))
    end
    { "account_unit" => "USD", "schedule" => { "kind" => "catalog_only", "rates" => rates } }
  end

  def decimal(value) = BigDecimal(value.to_s).to_s("F")
end

if $PROGRAM_NAME == __FILE__
  options = { root: File.expand_path("../config/model_catalog", __dir__), check: false }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby script/import_pi_catalog.rb [--source-json PATH] [--check]"
    parser.on("--source-json PATH", "Use an already extracted Pi provider-data JSON file") { |path| options[:source] = path }
    parser.on("--catalog-root PATH", "Catalog fragment directory") { |path| options[:root] = path }
    parser.on("--check", "Check generated files without modifying them") { options[:check] = true }
  end.parse!
  existing_providers = {}
  Dir.glob(File.join(options.fetch(:root), "*.yml")).sort.each do |path|
    next if File.basename(path).start_with?("80_pi_")
    data = YAML.safe_load_file(path)
    existing_providers.merge!(data.fetch("providers", {}))
  end
  source = options[:source] ? JSON.parse(File.read(options.fetch(:source))) : PiCatalogImport.download
  importer = PiCatalogImport.new(source: source, existing_providers: existing_providers)
  files = importer.fragments.to_h do |provider, fragment|
    header = "# Generated by script/import_pi_catalog.rb from @earendil-works/pi-ai@#{PiCatalogImport::VERSION}.\n" \
      "# Source-matched metadata; no live-provider qualification. Authored providers are excluded.\n"
    # Safe YAML forbids aliases; expand shared frozen declaration constants.
    ["80_pi_#{provider}.yml", header + YAML.dump(JSON.parse(JSON.generate(fragment)))]
  end
  files["pi_import_report.json"] = JSON.pretty_generate(importer.report) + "\n"
  stale = Dir.glob(File.join(options.fetch(:root), "80_pi_*.yml"))
    .reject { |path| files.key?(File.basename(path)) }
  if options.fetch(:check)
    raise "unexpected generated catalog files: #{stale.map { |path| File.basename(path) }.join(", ")}" if stale.any?
  else
    stale.each { |path| File.delete(path) }
  end
  files.each do |name, content|
    path = File.join(options.fetch(:root), name)
    if options.fetch(:check)
      raise "generated catalog differs: #{path}" unless File.file?(path) && File.read(path) == content
    else
      File.write(path, content)
    end
  end
  puts JSON.pretty_generate(importer.report.except("pending_apis", "unpriced"))
end
