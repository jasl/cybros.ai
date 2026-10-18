require "test_helper"

class API::V1::AdminModelTestTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    @policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    @token = create_access_token_fixture(user: users(:owner), name: "Model tests", plane: :platform)
  end

  test "an admin test returns only a bounded outcome and applies definite failure" do
    probe = ModelProviders::TestConnection::Result.new(outcome: :model_not_found, duration_ms: 12, http_status: 404)
    ModelProviders::TestConnection.stub(:call, probe) { run_test }
    assert_response :success
    assert_equal({ "outcome" => "model_not_found", "duration_ms" => 12, "http_status" => 404,
      "availability_update" => "applied" }, response.parsed_body.fetch("model_test"))
    assert_includes @policy.reload.model_overrides.fetch("unavailable_models"), "dev/mock-text"
  end

  test "availability edits retain admin rows and hide them from member discovery" do
    change(false)
    assert_response :success
    get "/api/v1/admin/models", headers: auth
    row = response.parsed_body.fetch("models").find { |model| model.fetch("ref") == "dev/mock-text" }
    assert_equal "model_unavailable", row.fetch("unavailable_reason")
    refute row.fetch("visible")
    member = create_access_token_fixture(user: users(:member), name: "Discovery")
    get "/agent_api/v1/models", headers: { "Authorization" => "Bearer #{member.secret}" }
    assert_response :success
    refute response.parsed_body.fetch("models").any? { |model| model.fetch("ref") == "dev/mock-text" }
    change(true)
    assert_response :success
    assert_empty @policy.reload.model_overrides.fetch("unavailable_models", [])
  end

  test "invalid availability and stale versions cannot change current settings" do
    change("false")
    assert_response :bad_request
    version = @policy.lock_version
    change(false)
    assert_response :success
    change(true, version: version)
    assert_response :conflict
    change(true, model: "test_api/text")
    assert_response :not_found
    assert_includes @policy.reload.model_overrides.fetch("unavailable_models"), "dev/mock-text"
  end

  test "model tests enforce model binding and version syntax before provider IO" do
    ModelProviders::TestConnection.stub(:call, ->(**) { flunk "must not call provider" }) do
      run_test(model: "test_api/text")
      assert_response :not_found
      run_test(model: "dev/unknown")
      assert_response :not_found
      run_test(version: -1)
      assert_response :bad_request
    end
  end

  test "model writes require an admin platform bearer and never accept a browser cookie" do
    ModelProviders::TestConnection.stub(:call, ->(**) { flunk "must not call provider" }) do
      sign_in_as users(:owner)
      run_test(headers: {})
      assert_response :unauthorized
      member_plane = create_access_token_fixture(user: users(:owner), name: "Wrong plane")
      ordinary = create_access_token_fixture(user: users(:member), name: "Ordinary", plane: :platform)
      [[member_plane, :unauthorized], [ordinary, :forbidden]].each do |token, status|
        headers = { "Authorization" => "Bearer #{token.secret}" }
        run_test(headers: headers)
        assert_response status
        change(false, headers: headers)
        assert_response status
      end
    end
  end

  private

    def auth = { "Authorization" => "Bearer #{@token.secret}" }

    def run_test(model: "dev/mock-text", version: @policy.reload.lock_version, headers: auth)
      post "/api/v1/admin/model_providers/dev/model_test", params: {
        command: { model: model, expected_lock_version: version },
      }, headers: headers, as: :json
    end

    def change(available, model: "dev/mock-text", version: @policy.reload.lock_version, headers: auth)
      put "/api/v1/admin/model_providers/dev/model_availability", params: {
        command: { model: model, available: available, expected_lock_version: version },
      }, headers: headers, as: :json
    end
end
