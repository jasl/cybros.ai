require "test_helper"

class Admin::ModelPromptCacheSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    sign_in_as users(:owner)
    @ref = "test_api/text"
    @definition = ModelCatalog.current.authored_models.fetch(@ref).deep_dup
    @definition["model_id"] ||= "text"
    @definition["capabilities"] ||= {}
    @definition["capabilities"]["generation_parameters"] ||= {}
    @definition["capabilities"]["generation_parameters"]["prompt_cache_ttl"] = {
      "allowed_values" => %w[30m 12h], "default" => nil,
    }
    result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "test_api",
      model_ref: @ref, model: @definition, validate_definition: true, expected_lock_version: nil)
    assert_predicate result, :done?
  end

  test "TTL choices follow the model and save changes only its default" do
    get admin_model_provider_model_definition_path("test_api", model: @ref)
    assert_response :success
    assert_select "select[name='model_definition[prompt_cache_ttl]']" do
      assert_select "option", count: 3
      assert_select "option[value=''][selected]"
      assert_select "option[value='30m']"
      assert_select "option[value='12h']"
    end
    original = saved_definition
    save_ttl("")
    assert_response :see_other
    assert_equal original, saved_definition
    save_ttl("12h")
    assert_response :see_other
    expected = original.deep_dup
    expected["capabilities"]["generation_parameters"]["prompt_cache_ttl"]["default"] = "12h"
    assert_equal expected, saved_definition
    get admin_model_provider_model_definition_path("test_api", model: @ref)
    assert_select "select[name='model_definition[prompt_cache_ttl]'] option[value='12h'][selected]"
    save_ttl("")
    assert_response :see_other
    assert_equal original, saved_definition
  end

  test "unsupported TTL and stale edits do not overwrite the saved choice" do
    original = saved_definition
    save_ttl("1h")
    assert_response :unprocessable_entity
    assert_equal original, saved_definition
    version = policy.lock_version
    save_ttl("12h")
    assert_response :see_other
    save_ttl("30m", version: version)
    assert_response :conflict
    assert_select "select[name='model_definition[prompt_cache_ttl]'] option[value='30m'][selected]"
    assert_equal "12h", saved_definition.dig("capabilities", "generation_parameters", "prompt_cache_ttl", "default")
  end

  test "models without a declared TTL offer no editable control" do
    get admin_model_provider_model_definition_path("codex_subscription", model: "codex_subscription/gpt-6.1-sol")
    assert_response :success
    assert_select "select[name='model_definition[prompt_cache_ttl]']:not([disabled])", count: 0
  end

  private

    def policy
      ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    end

    def saved_definition
      policy.override_entries.fetch(@ref).fetch("model")
    end

    def save_ttl(value, version: policy.lock_version)
      patch admin_model_provider_model_definition_path("test_api"), params: {
        model_definition: { model: @ref, model_id: @definition["model_id"] || "text",
          inherit: @definition["inherit"], pricing_mode: "preserve",
          expected_lock_version: version, prompt_cache_ttl: value },
      }
    end
end
