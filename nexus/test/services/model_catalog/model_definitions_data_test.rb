require "test_helper"
require "tmpdir"

class ModelCatalog::ModelDefinitionsDataTest < ActiveSupport::TestCase
  test "a deployment can serve the shipped Flash Next definition with its own model id and window" do
    Dir.mktmpdir("model-definitions-deployment") do |overrides|
      File.write(File.join(overrides, "local.yml"), {
        "schema_version" => ModelCatalog::FileBase::SCHEMA_VERSION,
        "providers" => {
          "local" => { "base_url" => "http://inference.example.test", "api_format" => "openai_compatible_chat" },
        },
        "models" => {
          "local/flash" => {
            "inherit" => "qwen3.8-flash-next",
            "model_id" => "served-flash",
            "limits" => { "input_tokens" => 32768, "output_tokens" => 4096 },
          },
        },
      }.to_yaml)

      catalog = shipped_catalog(override_dir: overrides)
      model = catalog.models.fetch("local/flash")
      profile = profile_for(catalog, "local/flash")

      assert_equal "served-flash", profile.model_pin
      assert_equal "openai_compatible_chat", profile.adapter_profile
      assert_equal "Qwen/Qwen3.8-Flash-Next", profile.token_counter.tokenizer_id
      assert_equal ["image"], profile.input_modalities
      assert_equal({ "input_tokens" => 32768, "output_tokens" => 4096 }, model.dig("capabilities", "limits"))
      refute model.key?("pricing")
      refute model.key?("model_identity")
      refute model.dig("capabilities").key?("reasoning_replay")
      assert_equal({ "combined_input_output_tokens" => 1000000, "output_tokens" => 131072 },
        catalog.models.fetch("openrouter/qwen/qwen3.8-flash").dig("capabilities", "limits"))
    end
  end

  test "shared OpenAI definitions retain the API and subscription media and service choices" do
    catalog = shipped_catalog
    %w[gpt-6-astra gpt-6.1-sol gpt-6-luna].each do |name|
      api = profile_for(catalog, "openai_api/#{name}")
      subscription = profile_for(catalog, "codex_subscription/#{name}")

      assert_equal api.local_safety_limits, subscription.local_safety_limits
      api_limits = Nexus::ModelCapabilityLimits.from_catalog(entry: catalog.models.fetch("openai_api/#{name}"), profile: api)
      subscription_limits = Nexus::ModelCapabilityLimits.from_catalog(entry: catalog.models.fetch("codex_subscription/#{name}"), profile: subscription)
      assert_equal 272_000, api_limits.planning_input_bound
      expected_bound = name == "gpt-6.1-sol" ? 500_000 : 272_000
      assert_equal expected_bound, subscription_limits.planning_input_bound
      assert_equal %w[image file], api.input_modalities
      assert_equal ["image"], subscription.input_modalities
      assert_equal %w[flex priority], api.service_tiers
      assert_equal ["priority"], subscription.service_tiers
      assert_equal %w[auto concise detailed], api.reasoning_options.fetch("summaries")
      assert_equal %w[none auto concise detailed], subscription.reasoning_options.fetch("summaries")
      refute catalog.model_definitions.fetch(name).key?("token_counter")
    end
  end

  test "shared DeepSeek definitions retain each serving lane's complete context window" do
    catalog = shipped_catalog
    {
      "deepseek-flash" => ["deepseek-v4.1-flash", 384000],
      "deepseek-v4-pro" => ["deepseek-v4-pro-0813", 393216],
    }.each do |direct_name, (model_name, broker_output)|
      direct_ref = "deepseek/#{direct_name}"
      broker_ref = "openrouter/deepseek/#{model_name}"
      direct = catalog.models.fetch(direct_ref).fetch("capabilities")
      broker = catalog.models.fetch(broker_ref).fetch("capabilities")

      assert_equal({ "combined_input_output_tokens" => 1048576, "output_tokens" => 393216 }, direct.fetch("limits"))
      assert_equal({ "input_tokens" => 1048576, "output_tokens" => broker_output }, broker.fetch("limits"))
      assert_equal %w[minimal low medium high xhigh max], direct.dig("reasoning", "efforts")
      assert_equal %w[low high max], broker.dig("reasoning", "efforts")
      assert_equal "responses_reasoning_text", direct.dig("reasoning_replay", "format")
      assert_equal "chat_reasoning", broker.dig("reasoning_replay", "format")
      assert_equal profile_for(catalog, direct_ref).token_counter, profile_for(catalog, broker_ref).token_counter
    end
  end

  private

    def shipped_catalog(override_dir: nil)
      ModelCatalog::FileBase.compile(root: Rails.root.join("config/model_catalog"), override_dir: override_dir)
    end

    def profile_for(catalog, ref)
      ModelCatalog::ProfileBuilder.call(
        model_ref: ref,
        provider: catalog.providers.fetch(ref.split("/", 2).first),
        model: catalog.models.fetch(ref)
      )
    end
end
