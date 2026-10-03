require "test_helper"

class API::V1::AdminModelProviderDefinitionsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @token = create_access_token_fixture(user: users(:owner), name: "Catalog settings", plane: :platform)
    @definition = { base_url: "http://127.0.0.1:11434/v1", api_format: "openai_compatible_chat", credentials: "none" }
  end

  test "custom provider and unpriced model appear through the ordinary model and credential paths" do
    put definition_path, params: { command: { definition: @definition, expected_lock_version: nil } }, as: :json, headers: auth
    assert_response :success
    assert_equal "custom", response.parsed_body.dig("configuration", "source")
    refute response.parsed_body.dig("model_provider", "enabled")
    version = response.parsed_body.dig("model_provider", "lock_version")

    put "#{provider_path}/model_definition", params: { command: {
      model: "local/text", definition: {}, expected_lock_version: version,
    } }, as: :json, headers: auth
    assert_response :success
    assert_equal "local/text", response.parsed_body.dig("configuration", "models", 0, "model")
    version = response.parsed_body.dig("model_provider", "lock_version")

    put "#{provider_path}/lane", params: { command: { enabled: true, expected_lock_version: version } }, as: :json, headers: auth
    assert_response :success
    get "/api/v1/admin/models", headers: auth
    assert_response :success
    model = response.parsed_body.fetch("models").find { |row| row.fetch("ref") == "local/text" }
    assert model.fetch("available")
    assert_equal "unmetered", model.dig("pricing", "state")
  end

  test "dotted provider IDs remain one resource segment throughout authoring" do
    path = "/api/v1/admin/model_providers/llama.cpp"
    put "#{path}/definition", params: { command: { definition: @definition, expected_lock_version: nil } }, as: :json, headers: auth
    assert_response :success
    assert_equal "llama.cpp", response.parsed_body.dig("model_provider", "id")
    get path, headers: auth
    assert_response :success
    assert_equal "llama.cpp", response.parsed_body.dig("model_provider", "id")
    assert_equal @definition.fetch(:base_url), response.parsed_body.dig("configuration", "definition", "base_url")
  end

  test "removed custom provider keeps a versioned authoring anchor and can be recreated" do
    create_provider
    version = response.parsed_body.dig("model_provider", "lock_version")
    delete definition_path, params: { command: { expected_lock_version: version } }, as: :json, headers: auth
    assert_response :success
    assert_equal "removed", response.parsed_body.dig("configuration", "source")
    assert_nil response.parsed_body.dig("configuration", "definition")
    version = response.parsed_body.dig("model_provider", "lock_version")

    get provider_path, headers: auth
    assert_response :success
    assert_equal version, response.parsed_body.dig("model_provider", "lock_version")
    get "/api/v1/admin/model_providers", headers: auth
    refute_includes response.parsed_body.fetch("model_providers").pluck("id"), "local"
    put definition_path, params: { command: { definition: @definition, expected_lock_version: version } }, as: :json, headers: auth
    assert_response :success
    assert_equal "custom", response.parsed_body.dig("configuration", "source")
  end

  test "authoring rejects invalid models and stale provider changes without modifying the catalog" do
    create_provider
    version = response.parsed_body.dig("model_provider", "lock_version")
    [{ future_contract: true }, { pricing: false }, { wire_options: "not-a-mapping" }].each do |definition|
      put "#{provider_path}/model_definition", params: { command: {
        model: "local/bad", definition: definition, expected_lock_version: version,
      } }, as: :json, headers: auth
      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    end
    put definition_path, params: { command: { definition: @definition.merge(display_name: "changed"), expected_lock_version: version + 1 } }, as: :json, headers: auth
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
    assert_empty ModelProviderPolicy.find_by!(account: @account, provider_id: "local").override_entries
  end

  test "model remove and reset restore the file definition" do
    ref = "dev/mock-image"
    put "/api/v1/admin/model_providers/dev/model_definition", params: { command: {
      model: ref, definition: ModelCatalog.current.models.fetch(ref).merge("display_name" => "Override"), expected_lock_version: nil,
    } }, as: :json, headers: auth
    assert_response :success
    version = response.parsed_body.dig("model_provider", "lock_version")
    delete "/api/v1/admin/model_providers/dev/model_definition", params: { command: { model: ref, expected_lock_version: version } }, as: :json, headers: auth
    assert_response :success
    version = response.parsed_body.dig("model_provider", "lock_version")
    post "/api/v1/admin/model_providers/dev/model_definition/reset", params: { command: { model: ref, expected_lock_version: version } }, as: :json, headers: auth
    assert_response :success
    row = response.parsed_body.dig("configuration", "models").find { |model| model.fetch("model") == ref }
    refute row.fetch("removed")
    assert_equal "catalog", row.fetch("source")
  end

  test "provider definitions cannot contain secrets and admin access is required" do
    put definition_path, params: { command: { definition: @definition.merge(api_key: "do-not-store"), expected_lock_version: nil } }, as: :json, headers: auth
    assert_response :unprocessable_entity
    assert_nil ModelProviderPolicy.find_by(account: @account, provider_id: "local")
    token = create_access_token_fixture(user: users(:member), name: "Member", plane: :platform)
    put definition_path, params: { command: { definition: @definition, expected_lock_version: nil } }, as: :json,
      headers: { "Authorization" => "Bearer #{token.secret}" }
    assert_response :unauthorized
  end

  private

    def auth = { "Authorization" => "Bearer #{@token.secret}" }
    def provider_path = "/api/v1/admin/model_providers/local"
    def definition_path = "#{provider_path}/definition"
    def create_provider
      put definition_path, params: { command: { definition: @definition, expected_lock_version: nil } }, as: :json, headers: auth
      assert_response :success
    end
end
