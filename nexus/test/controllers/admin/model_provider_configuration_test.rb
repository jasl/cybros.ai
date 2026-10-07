require "test_helper"

class Admin::ModelProviderConfigurationTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    sign_in_as users(:owner)
  end

  test "an administrator creates and edits a custom provider without credentials or network discovery" do
    ModelProviders::DiscoverModels.stub(:call, ->(**) { flunk "a settings read must not contact the provider" }) do
      get new_admin_model_provider_path
      assert_response :success
      assert_select "select[name='provider_definition[credentials]'] option[value=codex]", count: 0
      post admin_model_providers_path, params: { provider_definition: provider_fields }
      assert_redirected_to admin_model_provider_path("local-test")
      follow_redirect!
      assert_select "a", text: "Add model"
      assert_select "a", text: "Edit connection"
    end
    policy = provider_policy
    assert_not_predicate policy, :enabled?
    assert_equal "http://localhost:11434/v1", policy.provider_definition.fetch("base_url")
    assert_not ModelProviderCredential.exists?(account: @account, provider_id: "local-test")
    get admin_model_provider_definition_path("local-test")
    assert_response :success
    assert_select "input[name='provider_definition[provider_id]'][readonly]"
    patch admin_model_provider_definition_path("local-test"), params: {
      provider_definition: provider_fields.merge(base_url: "http://localhost:1234/v1", expected_lock_version: policy.lock_version),
    }
    assert_redirected_to admin_model_provider_path("local-test")
    assert_equal "http://localhost:1234/v1", policy.reload.provider_definition.fetch("base_url")
  end

  test "a provider ID containing a dot remains intact in browser routes" do
    post admin_model_providers_path, params: { provider_definition: provider_fields.merge(provider_id: "llama.cpp") }
    assert_redirected_to admin_model_provider_path("llama.cpp")
    follow_redirect!
    assert_response :success
    get admin_model_provider_definition_path("llama.cpp")
    assert_response :success
    assert_select "input[name='provider_definition[provider_id]'][value='llama.cpp']"
  end

  test "invalid and stale provider edits keep the entered values without overwriting a newer connection" do
    add_provider
    policy = provider_policy
    version = policy.lock_version
    patch admin_model_provider_definition_path("local-test"), params: {
      provider_definition: provider_fields.merge(base_url: "https://current.example", expected_lock_version: version),
    }
    assert_response :see_other
    patch admin_model_provider_definition_path("local-test"), params: {
      provider_definition: provider_fields.merge(base_url: "https://stale.example", expected_lock_version: version),
    }
    assert_response :conflict
    assert_select "[role=alert]", text: /changed in another session/
    assert_select "input[name='provider_definition[base_url]'][value='https://stale.example']"
    assert_equal "https://current.example", policy.reload.provider_definition.fetch("base_url")
    patch admin_model_provider_definition_path("local-test"), params: {
      provider_definition: provider_fields.merge(concurrency_limit: "no", expected_lock_version: policy.lock_version),
    }
    assert_response :unprocessable_entity
    assert_select "input[name='provider_definition[concurrency_limit]'][value=no][aria-invalid=true]"
  end

  test "a disabled custom provider supports manually authored unpriced models and optional zero prices" do
    add_provider
    post admin_model_provider_model_definition_path("local-test"), params: {
      model_definition: model_fields.merge(input_tokens: "32000", tool_calls: "false"),
    }
    assert_redirected_to admin_model_provider_path("local-test")
    row = configuration.fetch(:models).sole
    assert_equal "local-test/namespace/model", row.fetch(:model)
    assert_nil row.fetch(:definition)["pricing"]
    assert_equal 32000, row.fetch(:definition).dig("capabilities", "limits", "input_tokens")
    assert_equal false, row.fetch(:definition).dig("capabilities", "tool_calls")
    assert_not_predicate provider_policy, :enabled?

    patch admin_model_provider_model_definition_path("local-test"), params: {
      model_definition: model_fields.merge(model: row.fetch(:model), model_id: "namespace/revision", display_name: "My model",
        pricing_mode: "custom", pricing_unit: "USD", input_per_mtok: "0", output_per_mtok: "0"),
    }
    assert_response :see_other
    definition = configuration.fetch(:models).sole.fetch(:definition)
    assert_equal "namespace/revision", definition.fetch("model_id")
    assert_equal "0", definition.dig("pricing", "schedule", "rates", "input_per_mtok")
    get admin_model_provider_model_definition_path("local-test", model: row.fetch(:model))
    assert_response :success
    assert_select "input[name='model_definition[model_id]'][value='namespace/revision']"
    assert_select "select[name='model_definition[pricing_mode]'] option[value=preserve][selected]"
  end

  test "an invalid model formula does not save and stale model edits retain the draft" do
    add_provider
    post admin_model_provider_model_definition_path("local-test"), params: {
      model_definition: model_fields.merge(pricing_mode: "custom", pricing_unit: "USD", input_per_mtok: "0.5"),
    }
    assert_response :unprocessable_entity
    assert_empty configuration.fetch(:models)
    assert_select "input[name='model_definition[model_id]'][value='namespace/model']"
    post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields }
    assert_response :see_other
    stale = provider_policy.lock_version
    ModelProviders::DisableLane.call(account: @account, provider_id: "local-test", expected_lock_version: stale)
    ModelProviders::EnableLane.call(account: @account, provider_id: "local-test", expected_lock_version: provider_policy.lock_version)
    patch admin_model_provider_model_definition_path("local-test"), params: {
      model_definition: model_fields.merge(model: "local-test/namespace/model", display_name: "Draft name", expected_lock_version: stale),
    }
    assert_response :conflict
    assert_select "input[name='model_definition[display_name]'][value='Draft name']"
    assert_select "a[href=?]", admin_model_provider_model_definition_path("local-test", model: "local-test/namespace/model"), text: "Reload current settings"
  end

  test "catalog model edits preserve unexposed fields and reset restores the installation definition" do
    ref = "test_api/text"
    original = ModelCatalog.current.models.fetch(ref).deep_dup
    patch admin_model_provider_model_definition_path("test_api"), params: {
      model_definition: { model: ref, model_id: original["model_id"] || "text", display_name: "My Text", expected_lock_version: "" },
    }
    assert_response :see_other
    current = configuration("test_api").fetch(:models).find { |row| row.fetch(:model) == ref }.fetch(:definition)
    assert_equal original.except("display_name", "model_id"), current.except("display_name", "model_id")
    policy = provider_policy("test_api")
    post admin_model_provider_model_reset_path("test_api"), params: {
      model_reset: { model: ref, expected_lock_version: policy.lock_version },
    }
    assert_response :see_other
    assert_equal original, configuration("test_api").fetch(:models).find { |row| row.fetch(:model) == ref }.fetch(:definition)
  end

  test "an untouched installation model can be removed and restored without enabling the provider" do
    ref = "test_api/alternate"
    assert_not ModelProviderConfig.exists?(account: @account, provider_id: "test_api")
    delete admin_model_provider_model_definition_path("test_api"), params: {
      model_definition: { model: ref, expected_lock_version: "" },
    }
    assert_redirected_to admin_model_provider_path("test_api")
    assert_not_predicate provider_policy("test_api"), :enabled?
    row = configuration("test_api").fetch(:models).find { |model| model.fetch(:model) == ref }
    assert row.fetch(:removed)
    get admin_model_provider_model_definition_path("test_api", model: ref)
    assert_response :success
    assert_select "button", text: "Restore installation model"
    post admin_model_provider_model_reset_path("test_api"), params: {
      model_reset: { model: ref, expected_lock_version: provider_policy("test_api").lock_version },
    }
    assert_redirected_to admin_model_provider_path("test_api")
    assert_not_predicate provider_policy("test_api"), :enabled?
    assert_equal "catalog", configuration("test_api").fetch(:models).find { |model| model.fetch(:model) == ref }.fetch(:source)
  end

  test "model removal and custom connection removal retain addressable configuration" do
    add_provider
    post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields }
    delete admin_model_provider_model_definition_path("local-test"), params: {
      model_definition: { model: "local-test/namespace/model", expected_lock_version: provider_policy.lock_version },
    }
    assert_response :see_other
    get admin_model_provider_path("local-test")
    assert_select "summary", text: /Removed models/
    get admin_model_provider_model_definition_path("local-test", model: "local-test/namespace/model")
    assert_response :success
    assert_select "input[name='model_definition[model_id]'][value='namespace/model']"
    delete admin_model_provider_definition_path("local-test"), params: {
      provider_definition: { expected_lock_version: provider_policy.lock_version },
    }
    assert_redirected_to admin_model_providers_path
    get admin_model_provider_definition_path("local-test")
    assert_response :success
    assert_select "input[name='provider_definition[provider_id]'][value='local-test']"
    assert_select "input[name='provider_definition[expected_lock_version]'][value=?]", provider_policy.lock_version.to_s
    patch admin_model_provider_definition_path("local-test"), params: {
      provider_definition: provider_fields.merge(base_url: "https://replacement.example", expected_lock_version: provider_policy.lock_version),
    }
    assert_redirected_to admin_model_provider_path("local-test")
    follow_redirect!
    assert_response :success
    assert_equal "https://replacement.example", provider_policy.provider_definition.fetch("base_url")
    assert_not_predicate provider_policy, :enabled?
  end

  test "old model forms return to connection settings after the custom connection is removed" do
    add_provider
    post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields }
    draft = model_fields.merge(model: "local-test/namespace/model", display_name: "Unsaved model name")
    saved_models = provider_policy.model_overrides.deep_dup
    delete admin_model_provider_definition_path("local-test"), params: {
      provider_definition: { expected_lock_version: provider_policy.lock_version },
    }
    version = provider_policy.lock_version
    model_path = admin_model_provider_model_definition_path("local-test")
    requests = [
      [:get, new_admin_model_provider_model_definition_path("local-test"), {}],
      [:get, model_path, { model: "local-test/namespace/model" }],
      [:post, model_path, { model_definition: draft.except(:model).merge(model_id: "another-model") }],
      [:patch, model_path, { model_definition: draft }],
    ]
    requests.each do |method, path, body|
      public_send(method, path, params: body)
      assert_response :see_other
      assert_redirected_to admin_model_provider_definition_path("local-test")
      assert_equal version, provider_policy.lock_version
      assert_equal saved_models, provider_policy.model_overrides
    end
    follow_redirect!
    assert_response :success
    assert_select "input[name='provider_definition[provider_id]'][value='local-test']"
  end

  test "directory discovery is explicit and errors retain the manual entry route" do
    add_provider
    path = admin_model_provider_model_discovery_path("local-test")
    ModelProviders::DiscoverModels.stub(:call, ->(**) { flunk "GET cannot discover models" }) do
      get path
      assert_response :success
    end
    failure = ModelProviders::DiscoverModels::Result.new(outcome: :discovery_failed, models: [])
    ModelProviders::DiscoverModels.stub(:call, failure) do
      post path, params: { model_discovery: { expected_lock_version: provider_policy.lock_version } }
      assert_response :unprocessable_entity
      assert_select "turbo-frame#model-directory [role=alert]"
      assert_select "a[href=?]", new_admin_model_provider_model_definition_path("local-test"), text: "Enter a model ID manually"
    end
    result = ModelProviders::DiscoverModels::Result.new(outcome: :discovered, models: [{ id: "team/a+b", display_name: "Model A" }])
    ModelProviders::DiscoverModels.stub(:call, result) do
      post path, params: { model_discovery: { expected_lock_version: provider_policy.lock_version } }
      assert_response :success
      get new_admin_model_provider_model_definition_path("local-test", model_id: "team/a+b", display_name: "Model A")
      assert_response :success
      assert_select "input[name='model_definition[model_id]'][value='team/a+b']"
    end
  end

  test "browser commands reject missing versions and malformed field containers without changing definitions" do
    add_provider
    post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields }
    version = provider_policy.lock_version
    requests = [
      [:patch, admin_model_provider_definition_path("local-test"), { provider_definition: provider_fields.except(:expected_lock_version) }],
      [:delete, admin_model_provider_definition_path("local-test"), { provider_definition: { expected_lock_version: "-1" } }],
      [:post, admin_model_provider_model_definition_path("local-test"), { model_definition: ["bad"] }],
      [:patch, admin_model_provider_model_definition_path("local-test"), { model_definition: model_fields.merge(model: "local-test/namespace/model").except(:expected_lock_version) }],
      [:delete, admin_model_provider_model_definition_path("local-test"), { model_definition: { model: "local-test/namespace/model", expected_lock_version: "bad" } }],
      [:post, admin_model_provider_model_discovery_path("local-test"), { model_discovery: { expected_lock_version: "bad" } }],
      [:post, admin_model_provider_model_discovery_path("local-test"), { model_discovery: {} }],
      [:post, admin_model_provider_model_reset_path("local-test"), { model_reset: { model: "local-test/namespace/model" } }],
    ]
    requests.each do |method, path, body|
      public_send(method, path, params: body)
      assert_response :bad_request
      assert_equal version, provider_policy.lock_version
    end
  end

  test "directory results edit existing definitions and aliases while offering only new IDs for addition" do
    add_provider
    post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields }
    %w[alias-a alias-b].each do |local_id|
      post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields.merge(model_id: local_id) }
      assert_response :see_other
      patch admin_model_provider_model_definition_path("local-test"), params: {
        model_definition: model_fields.merge(model: "local-test/#{local_id}", model_id: "vendor/chat"),
      }
      assert_response :see_other
    end
    hidden = ModelProviders::SetModelVisibility.call(account: @account, provider_id: "local-test",
      model_ref: "local-test/alias-a", visible: false, expected_lock_version: provider_policy.lock_version)
    assert_predicate hidden, :done?
    unavailable = ModelProviders::SetModelAvailability.call(account: @account, provider_id: "local-test",
      model_ref: "local-test/alias-b", available: false, expected_lock_version: provider_policy.lock_version)
    assert_predicate unavailable, :done?
    definitions = configuration.fetch(:models)
    result = ModelProviders::DiscoverModels::Result.new(outcome: :discovered,
      models: %w[namespace/model vendor/chat team/a+b text].map { |id| { id: id } })
    ModelProviders::DiscoverModels.stub(:call, result) do
      post admin_model_provider_model_discovery_path("local-test"), params: { model_discovery: { expected_lock_version: provider_policy.lock_version } }
    end
    assert_response :success
    assert_select "li[data-model-id='namespace/model']" do
      assert_select ".badge", text: "Added"
      assert_select "a[href=?]", admin_model_provider_model_definition_path("local-test", model: "local-test/namespace/model"), text: "Edit model"
      assert_select "a", text: "Add model", count: 0
    end
    assert_select "li[data-model-id='vendor/chat']" do
      assert_select ".badge", text: "Added", count: 2
      %w[alias-a alias-b].each do |id|
        assert_select "a[href=?][data-turbo-frame='_top']", admin_model_provider_model_definition_path("local-test", model: "local-test/#{id}"), text: "Edit model"
      end
      assert_select "a", text: "Add model", count: 0
    end
    %w[team/a+b text].each do |id|
      assert_select "li[data-model-id=?] a[href=?]", id, new_admin_model_provider_model_definition_path("local-test", model_id: id), text: "Add model"
    end
    assert_equal definitions, configuration.fetch(:models)
  end

  test "directory results retain installation models and route removals to their existing settings" do
    delete admin_model_provider_model_definition_path("test_api"), params: {
      model_definition: { model: "test_api/alternate", expected_lock_version: "" },
    }
    assert_response :see_other
    result = ModelProviders::DiscoverModels::Result.new(outcome: :discovered, models: [{ id: "text" }, { id: "alternate" }])
    ModelProviders::DiscoverModels.stub(:call, result) do
      post admin_model_provider_model_discovery_path("test_api"), params: { model_discovery: { expected_lock_version: provider_policy("test_api").lock_version } }
    end
    assert_response :success
    assert_select "li[data-model-id=text]" do
      assert_select ".badge", text: "Added"
      assert_select "a[href=?]", admin_model_provider_model_definition_path("test_api", model: "test_api/text"), text: "Edit model"
    end
    assert_select "li[data-model-id=alternate]" do
      assert_select ".badge", text: "Removed"
      assert_select "a[href=?]", admin_model_provider_model_definition_path("test_api", model: "test_api/alternate"), text: "Review model"
    end
    assert_select "li a", text: "Add model", count: 0
  end

  test "directory results avoid duplicate addition for removed custom models and occupied local IDs" do
    add_provider
    post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields }
    delete admin_model_provider_model_definition_path("local-test"), params: {
      model_definition: { model: "local-test/namespace/model", expected_lock_version: provider_policy.lock_version },
    }
    assert_response :see_other
    post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields.merge(model_id: "occupied") }
    patch admin_model_provider_model_definition_path("local-test"), params: {
      model_definition: model_fields.merge(model: "local-test/occupied", model_id: "another-upstream-id"),
    }
    assert_response :see_other
    result = ModelProviders::DiscoverModels::Result.new(outcome: :discovered, models: [{ id: "namespace/model" }, { id: "occupied" }])
    ModelProviders::DiscoverModels.stub(:call, result) do
      post admin_model_provider_model_discovery_path("local-test"), params: { model_discovery: { expected_lock_version: provider_policy.lock_version } }
    end
    assert_response :success
    assert_select "li[data-model-id='namespace/model']" do
      assert_select ".badge", text: "Removed"
      assert_select "a[href=?]", admin_model_provider_model_definition_path("local-test", model: "local-test/namespace/model"), text: "Review model"
    end
    assert_select "li[data-model-id=occupied]" do
      assert_select ".badge", text: "Model ID in use"
      assert_select "a[href=?]", admin_model_provider_model_definition_path("local-test", model: "local-test/occupied"), text: "Edit model"
    end
    assert_select "li a", text: "Add model", count: 0
  end

  test "directory responses refresh the version after success failure and stale observations" do
    add_provider
    path = admin_model_provider_model_discovery_path("local-test")
    { discovered: :success, discovery_failed: :unprocessable_entity, stale: :conflict }.each do |outcome, status|
      version = provider_policy.lock_version
      probe = lambda do |expected_lock_version:, **|
        assert_equal version, expected_lock_version
        policy = provider_policy
        policy.update!(enabled: !policy.enabled)
        ModelProviders::DiscoverModels::Result.new(outcome: outcome, models: [])
      end
      ModelProviders::DiscoverModels.stub(:call, probe) do
        post path, params: { model_discovery: { expected_lock_version: version } }
        assert_response status
        assert_select "input[name='model_discovery[expected_lock_version]'][value=?]", provider_policy.lock_version.to_s
        assert_select "[role=alert]", text: /changed while the directory was being fetched/ if outcome == :stale
      end
    end
  end

  test "an explicitly absent cost estimate can be viewed and edited" do
    add_provider
    result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "local-test",
      model_ref: "local-test/null-price", model: { "pricing" => nil }, validate_definition: true,
      expected_lock_version: provider_policy.lock_version)
    assert_predicate result, :done?
    get admin_model_provider_model_definition_path("local-test", model: "local-test/null-price")
    assert_response :success
    assert_select "select[name='model_definition[pricing_mode]'] option[value=none][selected]"
  end

  test "ordinary members cannot author or discover provider definitions" do
    add_provider
    sign_out
    sign_in_as users(:member)
    [new_admin_model_provider_path, admin_model_provider_definition_path("local-test"),
      new_admin_model_provider_model_definition_path("local-test"), admin_model_provider_model_discovery_path("local-test")].each do |path|
      get path
      assert_response :forbidden
    end
    post admin_model_providers_path, params: { provider_definition: provider_fields.merge(provider_id: "denied") }
    assert_response :forbidden
    patch admin_model_provider_definition_path("local-test"), params: { provider_definition: provider_fields }
    assert_response :forbidden
    post admin_model_provider_model_definition_path("local-test"), params: { model_definition: model_fields }
    assert_response :forbidden
    post admin_model_provider_model_discovery_path("local-test")
    assert_response :forbidden
    assert_empty configuration.fetch(:models)
  end

  private

    def provider_fields
      { provider_id: "local-test", display_name: "Local test", api_format: "openai_compatible_chat",
        base_url: "http://localhost:11434/v1", credentials: "none", expected_lock_version: "" }
    end

    def add_provider
      post admin_model_providers_path, params: { provider_definition: provider_fields }
      assert_response :see_other
    end

    def model_fields
      { model_id: "namespace/model", pricing_mode: "none", expected_lock_version: provider_policy.lock_version }
    end

    def provider_policy(id = "local-test")
      ModelProviderConfig.find_by!(account: @account, provider_id: id)
    end

    def configuration(id = "local-test")
      API::ModelProviderConfigurationPresenter.one(account: @account, provider_id: id)
    end
end
