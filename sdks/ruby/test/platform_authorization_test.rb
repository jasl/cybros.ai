require "test_helper"
require "pp"

class PlatformAuthorizationTest < Minitest::Test
  PATH = "/api/v1/admin/model_providers/codex_subscription/authorization".freeze
  SESSION = {
    "public_id" => "01900000-0000-7000-8000-000000000071", "kind" => "device_start", "state" => "pending",
    "progress" => "awaiting_user", "outcome" => nil, "expires_at" => "2026-09-29T00:15:00Z",
    "verification_uri" => "https://auth.openai.com/codex/device", "user_code" => "TEST-CODE",
    "owned_by_current_user" => true,
  }.freeze
  STATUS = { "provider_id" => "codex_subscription", "state" => "pending", "expires_at" => nil, "session" => SESSION }.freeze

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "operator", transport: @transport)
  end

  def test_cost_unit_fetch_distinguishes_unconfigured_and_configured
    resource = client([[200, {}, { "account" => { "cost_unit" => nil } }],
                       [200, {}, { "account" => { "cost_unit" => "USD" } }]]).cost_unit
    assert_nil resource.fetch.cost_unit
    assert_equal "USD", resource.fetch.cost_unit
    assert @transport.requests.all? { |row| row.fetch(:method) == :get }
    assert_equal "/api/v1/admin/account/cost_unit", @transport.requests.first.fetch(:path)
  end

  def test_current_and_exact_session_reads_return_the_same_typed_projection
    resource = client([[200, {}, { "authorization" => STATUS }], [200, {}, { "authorization_session" => SESSION }]])
      .model_providers.provider("codex_subscription").authorization
    current = resource.fetch
    assert_equal "pending", current.state
    assert_nil current.expires_at
    assert_equal current.session, resource.session(SESSION.fetch("public_id")).fetch
    assert_equal "TEST-CODE", current.session.user_code
    assert_equal [PATH, "#{PATH}/sessions/#{SESSION.fetch("public_id")}"], @transport.requests.map { |row| row.fetch(:path) }
    [current.inspect, current.session.inspect, PP.pp(current, +"")].each { |text| refute_includes text, "TEST-CODE" }
  end

  def test_current_can_have_no_session_and_clear_retains_a_terminal_projection
    terminal = SESSION.merge("state" => "revoked", "outcome" => "operator_revoked", "user_code" => nil, "verification_uri" => nil)
    resource = client([[200, {}, { "authorization" => STATUS.merge("state" => "missing", "session" => nil) }],
                       [200, {}, { "authorization" => STATUS.merge("state" => "missing", "session" => terminal) }]])
      .model_providers.provider("codex_subscription").authorization
    assert_nil resource.fetch.session
    assert_equal "operator_revoked", resource.clear.session.outcome
    assert_equal [:get, :delete], @transport.requests.map { |row| row.fetch(:method) }
  end

  def test_start_and_explicit_restart_send_once_and_require_accepted
    resource = client([[202, {}, { "authorization_session" => SESSION }], [202, {}, { "authorization_session" => SESSION }]])
      .model_providers.provider("codex_subscription").authorization
    assert_equal SESSION.fetch("public_id"), resource.start.public_id
    assert_equal SESSION.fetch("public_id"), resource.start(restart: true).public_id
    assert_equal [{ "command" => { "restart" => false } }, { "command" => { "restart" => true } }],
      @transport.requests.map { |row| row.fetch(:body) }
    assert_equal [:post, :post], @transport.requests.map { |row| row.fetch(:method) }
  end

  def test_exact_session_consumes_the_nexus_exported_projection
    fixture = CybrosAgentTest::ContractFixtures.pack("models.json").fetch("authorization_session_fixture")
    expected = fixture.fetch("authorization_session")
    resource = client([[200, {}, fixture]]).model_providers.provider("codex_subscription").authorization
    actual = resource.session(expected.fetch("public_id")).fetch
    assert_equal expected, actual.to_h.transform_keys(&:to_s)
  end

  def test_start_errors_preserve_codes_and_do_not_retry
    [[409, "authorization_in_progress", CybrosAgent::Api::Conflict],
     [403, "administrator_required", CybrosAgent::Api::Forbidden],
     [502, "", CybrosAgent::Api::ServerError]].each do |status, code, type|
      resource = client([[status, {}, { "error" => { "code" => code } }]])
        .model_providers.provider("codex_subscription").authorization
      error = assert_raises(type) { resource.start }
      assert_equal code, error.code unless code.empty?
      assert_equal 1, @transport.requests.length
    end
    resource = client([[200, {}, { "authorization_session" => SESSION }]])
      .model_providers.provider("codex_subscription").authorization
    assert_raises(CybrosAgent::Api::MalformedResponse) { resource.start }
  end
end
