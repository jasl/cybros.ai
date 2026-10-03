require "test_helper"
require "pp"

class PlatformClientTest < Minitest::Test
  BASE_URL = "https://nexus.example".freeze
  SESSION = { "public_id" => "session-1", "kind" => "api", "expires_at" => "2026-10-29T00:00:00Z" }.freeze
  MEMBER = { "public_id" => "human-1", "kind" => "human", "role" => "admin" }.freeze
  LANE = {
    "id" => "openrouter", "credentials" => "api_key", "enabled" => true,
    "lock_version" => 3, "configured" => true, "material_kind" => "api_key",
    "reauthorization_required" => false, "models" => 12, "unavailable_until" => nil,
  }.freeze

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::PlatformClient.new(base_url: BASE_URL, credential: "platform-bearer", transport: @transport)
  end

  def sessions(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Sessions.new(base_url: BASE_URL, transport: @transport)
  end

  def request = @transport.requests.fetch(0)

  def test_login_posts_credentials_without_a_bearer_and_returns_the_show_once_grant
    grant = sessions([[201, {}, { "session" => SESSION, "token" => "private-login-token", "token_type" => "Bearer" }]])
      .create(email: "operator@example.test", password: "private-password")

    assert_equal "/api/v1/session", request.fetch(:path)
    assert_equal :post, request.fetch(:method)
    assert_nil request.fetch(:credential)
    assert_nil request.fetch(:params)
    assert_equal({ "email" => "operator@example.test", "password" => "private-password" }, request.fetch(:body))
    assert_equal "private-login-token", grant.token
    assert_equal "Bearer", grant.token_type
    assert_equal "session-1", grant.session.public_id
    assert_equal "2026-10-29T00:00:00Z", grant.session.expires_at
    [grant.inspect, grant.to_s, PP.pp(grant, +"")].each do |diagnostic|
      refute_includes diagnostic, "private-login-token"
      refute_includes diagnostic, "private-password"
    end
  end

  def test_login_preserves_typed_failure_codes_and_never_retries
    [
      [401, "invalid_credentials", CybrosAgent::Api::Unauthorized],
      [403, "password_change_required", CybrosAgent::Api::Forbidden],
      [429, "rate_limited", CybrosAgent::Api::RateLimited],
      [502, "", CybrosAgent::Api::ServerError],
    ].each do |status, code, error_class|
      login = sessions([[status, { "retry-after" => "180" }, { "error" => { "code" => code } }]])
      error = assert_raises(error_class) { login.create(email: "operator@example.test", password: "password") }
      assert_equal code, error.code unless code.empty?
      assert_equal 180, error.retry_after if status == 429
      assert_equal 1, @transport.requests.length
    end
  end

  def test_login_requires_the_created_status_and_complete_response
    [[200, { "session" => SESSION, "token" => "secret", "token_type" => "Bearer" }],
     [201, { "session" => SESSION, "token_type" => "Bearer" }]].each do |status, body|
      login = sessions([[status, {}, body]])
      assert_raises(CybrosAgent::Api::MalformedResponse) do
        login.create(email: "operator@example.test", password: "password")
      end
    end
  end

  def test_session_inspection_and_revocation_use_only_the_presented_bearer
    session = client([[200, {}, { "session" => SESSION }], [200, {}, { "revoked" => true }]]).session
    assert_equal "api", session.fetch.kind
    assert_nil session.revoke

    assert_equal ["/api/v1/session", "/api/v1/session"], @transport.requests.map { |row| row.fetch(:path) }
    assert_equal [:get, :delete], @transport.requests.map { |row| row.fetch(:method) }
    assert_equal ["platform-bearer", "platform-bearer"], @transport.requests.map { |row| row.fetch(:credential) }
    refute_respond_to session, :create
  end

  def test_session_revocation_refuses_a_false_success
    session = client([[200, {}, { "revoked" => false }]]).session
    assert_raises(CybrosAgent::Api::MalformedResponse) { session.revoke }
  end

  def test_profile_reads_the_human_and_preserves_the_session_or_platform_plane
    [nil, "platform"].each do |plane|
      profile = client([[200, {}, { "member" => MEMBER, "credential_plane" => plane }]]).profile.fetch
      assert_equal "/api/v1/profile", request.fetch(:path)
      assert_equal ["human-1", "human", "admin"], [profile.member.public_id, profile.member.kind, profile.member.role]
      if plane.nil?
        assert_nil profile.credential_plane
      else
        assert_equal plane, profile.credential_plane
      end
    end
  end

  def test_cost_unit_configuration_can_repeat_but_carries_a_conflict_without_retrying
    unit = client([
      [200, {}, { "account" => { "cost_unit" => "USD" } }],
      [200, {}, { "account" => { "cost_unit" => "USD" } }],
      [409, {}, { "error" => { "code" => "cost_unit_conflict" } }],
    ]).cost_unit
    2.times { assert_equal "USD", unit.configure("USD").cost_unit }
    error = assert_raises(CybrosAgent::Api::Conflict) { unit.configure("EUR") }

    assert_equal "cost_unit_conflict", error.code
    assert_equal 3, @transport.requests.length
    assert_equal "/api/v1/admin/account/cost_unit", request.fetch(:path)
    assert_equal :put, request.fetch(:method)
    assert_equal({ "account" => { "cost_unit" => "USD" } }, request.fetch(:body))
    refute request.fetch(:headers).key?("Idempotency-Key")
  end

  def test_model_listing_uses_the_admin_route_and_shared_typed_projection
    row = { "ref" => "openrouter/example", "provider" => "openrouter", "workload" => "text_generation",
            "visible" => true, "available" => true, "capabilities" => { "tool_calls" => true }, "pricing" => { "state" => "priced" } }
    model = client([[200, {}, { "models" => [row] }]]).models.list(workload: "text_generation", available: true).fetch(0)

    assert_equal "/api/v1/admin/models", request.fetch(:path)
    assert_equal({ "workload" => "text_generation", "available" => "true" }, request.fetch(:params))
    assert_instance_of CybrosAgent::Api::ModelCatalog::Model, model
    assert_predicate model, :available?
    assert_predicate model, :visible?
    assert_predicate model, :tool_calls?
    assert_predicate model.pricing, :priced?
  end

  def test_unfiltered_admin_listing_includes_unavailable_models_and_their_reasons
    row = { "ref" => "openrouter/example", "provider" => "openrouter", "workload" => "text_generation",
            "visible" => true, "available" => false, "unavailable_reason" => "missing_credential", "pricing" => { "state" => "priced" } }
    model = client([[200, {}, { "models" => [row] }]]).models.list.fetch(0)

    assert_equal "/api/v1/admin/models", request.fetch(:path)
    assert_nil request.fetch(:params)
    refute_predicate model, :available?
    assert_equal "missing_credential", model.unavailable_reason
  end

  def test_hidden_models_retain_their_pricing_in_the_administrative_projection
    row = { "ref" => "openrouter/example", "provider" => "openrouter", "workload" => "text_generation",
            "visible" => false, "available" => false, "unavailable_reason" => "model_hidden",
            "pricing" => { "state" => "priced", "unit" => "USD", "input_per_mtok" => "1.25" } }
    model = client([[200, {}, { "models" => [row] }]]).models.list.fetch(0)

    refute_predicate model, :visible?
    refute_predicate model, :available?
    assert_equal "model_hidden", model.unavailable_reason
    assert_equal "1.25", model.pricing.input_per_mtok
  end

  def test_provider_listing_and_single_read_share_the_member_projection
    providers = client([[200, {}, { "model_providers" => [LANE] }], [200, {}, { "model_provider" => LANE }]])
      .model_providers
    listed = providers.list.fetch(0)
    fetched = providers.provider("openrouter").fetch

    assert_equal listed, fetched
    assert_instance_of CybrosAgent::Api::ModelProviders::Lane, fetched
    assert_equal ["/api/v1/admin/model_providers", "/api/v1/admin/model_providers/openrouter"],
      @transport.requests.map { |row| row.fetch(:path) }
  end

  def test_serving_control_carries_the_version_it_was_read_at
    provider = client([[200, {}, { "model_provider" => LANE }]]).model_providers.provider("openrouter")
    provider.disable(expected_lock_version: 3)

    assert_equal :put, request.fetch(:method)
    assert_equal "/api/v1/admin/model_providers/openrouter/lane", request.fetch(:path)
    assert_equal({ "command" => { "enabled" => false, "expected_lock_version" => 3 } }, request.fetch(:body))
  end

  def test_enabling_an_untouched_lane_expects_no_version
    client([[200, {}, { "model_provider" => LANE }]]).model_providers.provider("openrouter").enable

    assert_equal({ "command" => { "enabled" => true, "expected_lock_version" => nil } }, request.fetch(:body))
  end

  def test_key_rotation_and_removal_never_read_the_key_back
    provider = client([[200, {}, { "model_provider" => LANE }],
                       [200, {}, { "model_provider" => LANE.merge("configured" => false) }]])
      .model_providers.provider("openrouter")
    lane = provider.install_api_key("provider-secret")
    refute_predicate provider.remove_api_key, :configured?

    assert_equal [:put, :delete], @transport.requests.map { |row| row.fetch(:method) }
    assert_equal ["/api/v1/admin/model_providers/openrouter/api_key"] * 2,
      @transport.requests.map { |row| row.fetch(:path) }
    assert_equal({ "command" => { "api_key" => "provider-secret" } }, request.fetch(:body))
    assert_predicate lane, :configured?
    refute_includes lane.members, :api_key
    refute_includes lane.members, :secret
  end

  def test_model_visibility_uses_the_full_reference_and_provider_policy_version
    provider = client([[200, {}, { "model_provider" => LANE.merge("lock_version" => 4) }],
                       [200, {}, { "model_provider" => LANE.merge("lock_version" => 5) }]])
      .model_providers.provider("openrouter")
    hidden = provider.set_model_visibility(model: "openrouter/vendor/model", visible: false, expected_lock_version: 3)
    restored = provider.set_model_visibility(model: "openrouter/vendor/model", visible: true,
      expected_lock_version: hidden.lock_version)

    assert_equal [4, 5], [hidden.lock_version, restored.lock_version]
    assert_equal [:put, :put], @transport.requests.map { |row| row.fetch(:method) }
    assert_equal ["/api/v1/admin/model_providers/openrouter/model_visibility"] * 2,
      @transport.requests.map { |row| row.fetch(:path) }
    assert_equal [
      { "command" => { "model" => "openrouter/vendor/model", "visible" => false, "expected_lock_version" => 3 } },
      { "command" => { "model" => "openrouter/vendor/model", "visible" => true, "expected_lock_version" => 4 } },
    ], @transport.requests.map { |row| row.fetch(:body) }
  end

  def test_visibility_refusals_preserve_codes_without_retries_or_enabling_a_lane
    [[404, "not_found", CybrosAgent::Api::NotFound, nil],
     [409, "stale_object", CybrosAgent::Api::Conflict, 3]].each do |status, code, error_class, version|
      provider = client([[status, {}, { "error" => { "code" => code } }]])
        .model_providers.provider("openrouter")
      error = assert_raises(error_class) do
        provider.set_model_visibility(model: "openrouter/example", visible: false, expected_lock_version: version)
      end
      assert_equal code, error.code
      assert_equal 1, @transport.requests.length
    end
  end

  def test_a_provider_id_is_one_immutable_path_segment
    id = +"lane/part?#"
    provider = client([[200, {}, { "model_provider" => LANE }]]).model_providers.provider(id)
    id.replace("elsewhere")
    provider.fetch
    assert_equal "/api/v1/admin/model_providers/lane%2Fpart%3F%23", request.fetch(:path)
  end

  def test_admin_and_version_refusals_are_not_retried
    [
      [401, "unauthorized", CybrosAgent::Api::Unauthorized],
      [403, "administrator_required", CybrosAgent::Api::Forbidden],
      [404, "not_found", CybrosAgent::Api::NotFound],
      [409, "stale_object", CybrosAgent::Api::Conflict],
      [503, "model_plane_unavailable", CybrosAgent::Api::ServerError],
    ].each do |status, code, error_class|
      provider = client([[status, {}, { "error" => { "code" => code } }]]).model_providers.provider("openrouter")
      error = assert_raises(error_class) { provider.disable(expected_lock_version: 3) }
      assert_equal code, error.code
      assert_equal 1, @transport.requests.length
    end
  end

  def test_the_platform_client_does_not_offer_execution_or_member_resources
    platform = client([])
    %i[workspaces workspace uploads tools executors].each { |name| refute_respond_to platform, name }
    assert_empty @transport.requests
  end
end
