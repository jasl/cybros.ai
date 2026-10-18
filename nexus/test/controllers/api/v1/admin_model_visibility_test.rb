require "test_helper"

class API::V1::AdminModelVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    @policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    @token = create_access_token_fixture(user: users(:owner), name: "Visibility", plane: :platform)
  end

  def auth = { "Authorization" => "Bearer #{@token.secret}" }

  def change(visible, model: "dev/mock-text", version: @policy.reload.lock_version, headers: auth)
    put "/api/v1/admin/model_providers/dev/model_visibility",
      params: { command: { model: model, visible: visible, expected_lock_version: version } },
      headers: headers, as: :json
  end

  def models(query = nil)
    get ["/api/v1/admin/models", query].compact.join("?"), headers: auth
    assert_response :success
    response.parsed_body.fetch("models")
  end

  test "hide and restore preserve the full model while member discovery only exposes available models" do
    before = models.find { |row| row.fetch("ref") == "dev/mock-text" }
    change(false)
    assert_response :success
    assert_equal @policy.reload.lock_version, response.parsed_body.dig("model_provider", "lock_version")

    hidden = models.find { |row| row.fetch("ref") == "dev/mock-text" }
    assert_equal before.merge("visible" => false, "available" => false, "unavailable_reason" => "model_hidden"), hidden
    refute models("available=true").any? { |row| row.fetch("ref") == "dev/mock-text" }

    member = create_access_token_fixture(user: users(:member), name: "Discovery")
    get "/agent_api/v1/models?available=false", headers: { "Authorization" => "Bearer #{member.secret}" }
    assert_response :success
    refute response.parsed_body.fetch("models").any? { |row| row.fetch("ref") == "dev/mock-text" }

    change(true)
    assert_response :success
    assert_equal before, models.find { |row| row.fetch("ref") == "dev/mock-text" }
    assert_empty @policy.reload.override_entries
  end

  test "admin default lists unavailable catalog entries and available narrows them" do
    full = models
    assert_equal ModelCatalog.current.models.keys.sort, full.map { |row| row.fetch("ref") }
    assert full.any? { |row| !row.fetch("available") }
    assert models("available=true").all? { |row| row.fetch("available") }
  end

  test "same value is a no-op and stale changed value cannot overwrite it" do
    version = @policy.lock_version
    change(false, version: version)
    assert_response :success
    after = @policy.reload.lock_version
    change(false)
    assert_response :success
    assert_equal after, @policy.reload.lock_version
    change(true, version: version)
    assert_response :conflict
    assert @policy.reload.model_overrides.fetch("hidden_models", []).include?("dev/mock-text")
  end

  test "a disabled provider can be configured without enabling it" do
    @policy.update!(enabled: false)
    change(false)
    assert_response :success
    refute response.parsed_body.dig("model_provider", "enabled")
    assert @policy.reload.model_overrides.fetch("hidden_models", []).include?("dev/mock-text")
  end

  test "invalid values and unknown or cross-provider models leave visibility unchanged" do
    change("false")
    assert_response :bad_request
    change(false, model: "dev/not-configured")
    assert_response :not_found
    change(false, model: "test_api/text")
    assert_response :not_found
    change(false, version: "invalid")
    assert_response :bad_request
    refute @policy.reload.model_overrides.fetch("hidden_models", []).include?("dev/mock-text")
  end

  test "initial visibility is saved without enabling the provider or configuring credentials" do
    before = models.find { |row| row.fetch("ref") == "test_api/text" }
    put "/api/v1/admin/model_providers/test_api/model_visibility",
      params: { command: { model: "test_api/text", visible: false, expected_lock_version: nil } },
      headers: auth, as: :json
    assert_response :success
    lane = response.parsed_body.fetch("model_provider")
    assert_equal 0, lane.fetch("lock_version")
    refute lane.fetch("enabled")
    refute lane.fetch("configured")
    assert_equal before.merge("visible" => false), models.find { |row| row.fetch("ref") == "test_api/text" }
    refute ModelProviderCredential.exists?(account: @account, provider_id: "test_api")

    put "/api/v1/admin/model_providers/test_api/model_visibility",
      params: { command: { model: "test_api/text", visible: true, expected_lock_version: lane.fetch("lock_version") } },
      headers: auth, as: :json
    assert_response :success
    refute response.parsed_body.dig("model_provider", "enabled")
    assert_equal before, models.find { |row| row.fetch("ref") == "test_api/text" }
  end

  test "an initial visible choice returns a disabled lane with a version for later edits" do
    put "/api/v1/admin/model_providers/test_api/model_visibility",
      params: { command: { model: "test_api/text", visible: true, expected_lock_version: nil } },
      headers: auth, as: :json
    assert_response :success
    lane = response.parsed_body.fetch("model_provider")
    assert_equal 0, lane.fetch("lock_version")
    refute lane.fetch("enabled")
    refute lane.fetch("configured")
    assert_empty ModelProviderConfig.find_by!(account: @account, provider_id: "test_api").model_overrides.fetch("hidden_models", [])
  end

  test "exceeding the shared ref limit refuses the whole visibility write" do
    @policy.update!(model_overrides: ModelProviderConfig.empty_overrides.merge(
      "hidden_models" => (1..ModelProviderConfig::MAX_OVERRIDE_REFS).map { |i| "dev/future-#{i}" }
    ))
    before = @policy.model_overrides.deep_dup
    change(false)
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal before, @policy.reload.model_overrides
  end

  test "only a human operator platform credential may change visibility" do
    member = create_access_token_fixture(user: users(:member), name: "Member")
    change(false, headers: { "Authorization" => "Bearer #{member.secret}" })
    assert_response :unauthorized
    ordinary = create_access_token_fixture(user: users(:member), name: "Ordinary", plane: :platform)
    change(false, headers: { "Authorization" => "Bearer #{ordinary.secret}" })
    assert_response :forbidden
    post "/api/v1/session", params: { email: identities(:member).email, password: "password" }, as: :json
    assert_response :created
    change(false, headers: { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" })
    assert_response :forbidden
    refute @policy.reload.model_overrides.fetch("hidden_models", []).include?("dev/mock-text")
  end
end
