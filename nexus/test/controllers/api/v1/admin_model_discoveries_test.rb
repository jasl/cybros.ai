require "test_helper"

class API::V1::AdminModelDiscoveriesTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @token = create_access_token_fixture(user: users(:owner), name: "Model directory", plane: :platform)
    result = ModelProviders::SetDefinition.call(account: @account, provider_id: "directory-test", expected_lock_version: nil,
      definition: { "base_url" => "http://127.0.0.1:1", "api_format" => "openai_compatible_chat", "credentials" => "none" })
    assert_predicate result, :done?
    @policy = result.policy
  end

  test "discovery passes the required version and returns the complete directory" do
    models = [{ id: "example-model", display_name: "Example" }]
    probe = lambda do |account:, provider_id:, expected_lock_version:|
      assert_equal @account, account
      assert_equal "directory-test", provider_id
      assert_equal @policy.lock_version, expected_lock_version
      ModelProviders::DiscoverModels::Result.new(outcome: :discovered, models: models)
    end
    ModelProviders::DiscoverModels.stub(:call, probe) do
      post path, params: { command: { expected_lock_version: @policy.lock_version } }, as: :json, headers: auth
      assert_response :success
      assert_equal({ "models" => models.map(&:stringify_keys) }, response.parsed_body)
    end
  end

  test "an explicit null version is accepted for a missing anchor" do
    probe = lambda do |expected_lock_version:, **|
      assert_nil expected_lock_version
      ModelProviders::DiscoverModels::Result.new(outcome: :discovered, models: [])
    end
    ModelProviders::DiscoverModels.stub(:call, probe) do
      post "/api/v1/admin/model_providers/dev/model_discovery",
        params: { command: { expected_lock_version: nil } }, as: :json, headers: auth
      assert_response :success
    end
  end

  test "missing malformed and out-of-range versions refuse before provider IO" do
    [{}, { command: {} }, { command: [] }, { command: { expected_lock_version: "invalid" } },
      { command: { expected_lock_version: -1 } }, { command: { expected_lock_version: 2_147_483_648 } }].each do |body|
      ModelProviders::DiscoverModels.stub(:call, ->(**) { flunk "invalid commands cannot fetch a directory" }) do
        post path, params: body, as: :json, headers: auth
        assert_response :bad_request
      end
    end
  end

  test "stale observations are conflicts and other failures remain validation failures" do
    { stale: :conflict, discovery_failed: :unprocessable_entity, invalid: :unprocessable_entity,
      missing_credential: :unprocessable_entity }.each do |outcome, status|
      result = ModelProviders::DiscoverModels::Result.new(outcome: outcome, models: [])
      ModelProviders::DiscoverModels.stub(:call, result) do
        post path, params: { command: { expected_lock_version: @policy.lock_version } }, as: :json, headers: auth
        assert_response status
        assert_equal outcome == :stale ? "stale_object" : "validation_failed", response.parsed_body.dig("error", "code")
      end
    end
  end

  test "ordinary members cannot fetch a directory or reconcile availability" do
    token = create_access_token_fixture(user: users(:member), name: "Member", plane: :platform)
    ModelProviders::DiscoverModels.stub(:call, ->(**) { flunk "members cannot fetch a directory" }) do
      post path, params: { command: { expected_lock_version: @policy.lock_version } }, as: :json,
        headers: { "Authorization" => "Bearer #{token.secret}" }
      assert_response :forbidden
    end
  end

  private

    def path = "/api/v1/admin/model_providers/directory-test/model_discovery"
    def auth = { "Authorization" => "Bearer #{@token.secret}" }
end
