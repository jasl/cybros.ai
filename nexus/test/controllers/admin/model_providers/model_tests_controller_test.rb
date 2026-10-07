require "test_helper"
require_relative "../../../test_helpers/rate_limit_test_helper"

class Admin::ModelProviders::ModelTestsControllerTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper
  setup do
    @account = accounts(:cybros)
    @model = "test_api/text"
    @policy = ModelProviders::EnableLane.call(account: @account, provider_id: "test_api", expected_lock_version: nil).policy
    sign_in_as users(:owner)
  end

  test "overview groups model actions and visiting the test page performs no provider request" do
    ModelProviders::TestConnection.stub(:call, ->(**) { flunk "GET must not test the provider" }) do
      get admin_model_provider_path("test_api")
      assert_response :success
      assert_select "#provider-models a[href=?]", admin_model_provider_model_discovery_path("test_api")
      assert_select "#provider-models a[href=?]", new_admin_model_provider_model_definition_path("test_api")
      assert_select "li[data-model-ref=?] a", @model, text: "Test"
      get admin_model_provider_model_test_path("test_api", model: @model)
      assert_response :success
      assert_select "input[type=submit][value=?]", "Run connection test"
      assert_includes response.body, "may incur provider charges"
    end
  end

  test "definite model failure is shown safely and invalidates the retained model" do
    with_probe(:model_not_found, status: 404) { run_test }
    assert_response :success
    assert_select "[role=status]", text: /no longer exists/
    assert_includes @policy.reload.model_overrides.fetch("unavailable_models"), @model
    get admin_model_provider_path("test_api")
    assert_select "li[data-model-ref=?]", @model, text: /Invalid · hidden from agents/
    assert_select "li[data-model-ref=?] button[aria-label=?]", @model, "Clear invalid mark for #{@model}"
  end

  test "successful retest clears invalidity but preserves manual hiding" do
    @policy.set_model_visibility(@model, visible: false)
    @policy.set_model_availability(@model, available: false)
    @policy.save!
    with_probe(:succeeded) { run_test }
    assert_response :success
    assert_select "[role=status]", text: /Connection succeeded/
    assert_empty @policy.reload.model_overrides.fetch("unavailable_models", [])
    assert_includes @policy.model_overrides.fetch("hidden_models"), @model
  end

  test "newer settings win when a probe returns after another edit" do
    version = @policy.lock_version
    probe = ->(**) do
      @policy.update!(enabled: false)
      ModelProviders::TestConnection::Result.new(outcome: :model_not_found, duration_ms: 12, http_status: 404)
    end
    ModelProviders::TestConnection.stub(:call, probe) { run_test(version: version) }
    assert_response :success
    assert_select "[role=status]", text: /Settings changed during this test/
    assert_empty @policy.reload.model_overrides.fetch("unavailable_models", [])
  end

  test "other probe failures leave model policy unchanged" do
    before = @policy.attributes
    %i[authentication_failed rate_limited timed_out provider_error connection_failed].each do |outcome|
      with_probe(outcome) { run_test }
      assert_response :success
      assert_equal before, @policy.reload.attributes
    end
  end

  test "rate limiting renders feedback inside the test frame without another provider request" do
    keys = capture_rate_limit_keys { with_probe(:succeeded) { run_test } }
    key = keys.uniq.sole
    Rails.cache.write(key, 10, expires_in: 3.minutes)
    ModelProviders::TestConnection.stub(:call, ->(**) { flunk "rate limited test cannot call provider" }) do
      run_test
      assert_response :too_many_requests
      assert_select "turbo-frame#model-connection-test [role=alert]", text: /Too many model tests/
    end
  ensure
    Rails.cache.delete(key) if key
  end

  test "manual invalidation and restoration preserve definitions and manual visibility" do
    @policy.set_model_visibility(@model, visible: false)
    @policy.save!
    original = ModelCatalog.current.models.fetch(@model)
    [false, true].each do |available|
      patch admin_model_provider_model_availability_path("test_api"), params: {
        model_availability: { model: @model, available: available.to_s, expected_lock_version: @policy.reload.lock_version },
      }
      assert_redirected_to admin_model_provider_path("test_api")
      assert_equal !available, @policy.reload.model_overrides.fetch("unavailable_models", []).include?(@model)
      assert_includes @policy.model_overrides.fetch("hidden_models"), @model
    end
    assert_equal original, ModelCatalog.current.models.fetch(@model)
  end

  test "unknown or cross-provider models cannot reach a probe and members cannot test" do
    ModelProviders::TestConnection.stub(:call, ->(**) { flunk "must not call provider" }) do
      ["test_api/unknown", "dev/mock-text"].each do |model|
        run_test(model: model)
        assert_response :not_found
      end
      sign_out
      sign_in_as users(:member)
      run_test
      assert_response :forbidden
      get admin_model_provider_model_test_path("test_api", model: @model)
      assert_response :forbidden
    end
  end

  private

    def run_test(model: @model, version: @policy.reload.lock_version)
      post admin_model_provider_model_test_path("test_api"), params: {
        model_test: { model: model, expected_lock_version: version },
      }
    end

    def with_probe(outcome, status: nil, &block)
      probe = ModelProviders::TestConnection::Result.new(outcome: outcome, duration_ms: 12, http_status: status)
      ModelProviders::TestConnection.stub(:call, probe, &block)
    end
end
