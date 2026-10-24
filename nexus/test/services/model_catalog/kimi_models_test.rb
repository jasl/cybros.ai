require "test_helper"

class ModelCatalog::KimiModelsTest < ActiveSupport::TestCase
  setup do
    @catalog = ModelCatalog::FileBase.compile(root: Rails.root.join("config/model_catalog"), override_dir: nil)
  end

  test "Kimi Code exposes the four exact model IDs with their documented windows and thinking controls" do
    %w[k3 k3-256k k3.1-pro k3.1-pro-highspeed].each do |id|
      ref = "kimi_code/#{id}"
      model = @catalog.models.fetch(ref)
      profile = profile_for(ref)
      assert_equal id, profile.model_pin
      assert_equal "openai_compatible_chat", profile.adapter_profile
      assert_equal ["image"], profile.input_modalities
      window = id == "k3-256k" ? 262_144 : 1_048_576
      assert_equal window, profile.local_safety_limits.combined_input_output_tokens
      assert_nil profile.local_safety_limits.output_tokens, "no unpublished completion ceiling"
      assert_equal %w[low high max], profile.reasoning_options.fetch("efforts")
      assert_equal false, model.dig("capabilities", "reasoning", "disable_supported")
      assert_nil model.fetch("pricing"), "a subscription is not free per-token inference"
      assert_nil model["token_counter"], "no guessed weight/tokenizer repository"
    end
  end

  test "regional API routes use independent providers and API platform IDs" do
    { "moonshot" => "https://api.moonshot.cn", "moonshot_global" => "https://api.moonshot.ai" }.each do |provider, url|
      assert_equal url, @catalog.providers.fetch(provider).fetch("base_url")
      %w[kimi-k3.1-pro kimi-k3.1-pro-highspeed].each do |id|
        ref = "#{provider}/#{id}"
        profile = profile_for(ref)
        assert_equal id, profile.model_pin
        assert_equal 1_048_576, profile.local_safety_limits.combined_input_output_tokens
        assert_equal "max", @catalog.models.fetch(ref).dig("capabilities", "reasoning", "default_effort")
        assert_nil @catalog.models.fetch(ref).fetch("pricing")
      end
    end
    refute @catalog.models.keys.any? { |ref| ref.start_with?("moonshot/kimi-k2") }
  end

  private

    def profile_for(ref)
      ModelCatalog::ProfileBuilder.call(model_ref: ref,
        provider: @catalog.providers.fetch(ref.split("/", 2).first), model: @catalog.models.fetch(ref))
    end
end
