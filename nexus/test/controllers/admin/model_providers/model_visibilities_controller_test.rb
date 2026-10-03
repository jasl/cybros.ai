require "test_helper"

class Admin::ModelProviders::ModelVisibilitiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @path = admin_model_provider_model_visibility_path("test_api")
    @model = "test_api/text"
    @policy = ModelProviders::EnableLane.call(account: @account, provider_id: "test_api", expected_lock_version: nil).policy
    sign_in_as users(:owner)
  end

  test "visibility uses the displayed version and keeps the catalog definition" do
    original = ModelCatalog.current.models.fetch(@model)
    version = @policy.lock_version
    patch @path, params: { model_visibility: { model: @model, visible: "false", expected_lock_version: version } }
    assert_redirected_to admin_model_provider_path("test_api")
    assert_response :see_other
    assert_hidden true
    get @path
    assert_response :success
    assert_includes response.body, @model
    assert_select "input[name=?][value=?]", "model_visibility[expected_lock_version]", @policy.reload.lock_version.to_s

    patch @path, params: { model_visibility: { model: @model, visible: "true", expected_lock_version: version } }
    assert_response :conflict
    assert_select "[role=alert]"
    assert_hidden true
    patch @path, params: { model_visibility: { model: @model, visible: "true", expected_lock_version: @policy.reload.lock_version } }
    assert_redirected_to admin_model_provider_path("test_api")
    assert_hidden false
    assert_equal original, ModelCatalog.current.models.fetch(@model)
  end

  test "a provider page cannot modify another provider or an invented model" do
    ["dev/default", "test_api/not-a-model"].each do |model|
      patch @path, params: { model_visibility: { model: model, visible: "false", expected_lock_version: @policy.lock_version } }
      assert_response :not_found
    end
    assert_hidden false
  end

  test "a fresh lane explains initialization while a disabled existing lane remains editable" do
    provider_id = "openrouter"
    path = admin_model_provider_model_visibility_path(provider_id)
    model = ModelCatalog.current.models.keys.find { |ref| Nexus::ModelRef.parse(ref).provider_id == provider_id }
    assert_not ModelProviderPolicy.exists?(account: @account, provider_id: provider_id)
    get path
    assert_response :success
    assert_select "a[href=?]", admin_model_provider_lane_path(provider_id), text: "Enable this provider"
    assert_select "li[data-model-ref=?] button[disabled]", model, count: 2
    patch path, params: { model_visibility: { model: model, visible: "false", expected_lock_version: "" } }
    assert_response :unprocessable_entity
    assert_not ModelProviderPolicy.exists?(account: @account, provider_id: provider_id)

    policy = ModelProviders::EnableLane.call(account: @account, provider_id: provider_id, expected_lock_version: nil).policy
    ModelProviders::DisableLane.call(account: @account, provider_id: provider_id, expected_lock_version: policy.lock_version)
    get path
    assert_response :success
    assert_select "li[data-model-ref=?] button:not([disabled])", model, count: 1
    patch path, params: { model_visibility: { model: model, visible: "false", expected_lock_version: policy.reload.lock_version } }
    assert_redirected_to admin_model_provider_path(provider_id)
    assert_not_predicate policy.reload, :enabled?
    catalog = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, provider_id)
    assert_includes catalog.hidden_models, model
  end

  test "ordinary members cannot change model visibility" do
    sign_out
    sign_in_as users(:member)
    patch @path, params: { model_visibility: { model: @model, visible: "false", expected_lock_version: @policy.lock_version } }
    assert_response :forbidden
    assert_hidden false
  end

  private

    def assert_hidden(expected)
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, "test_api")
      assert_equal expected, catalog.hidden_models.include?(@model)
    end
end
