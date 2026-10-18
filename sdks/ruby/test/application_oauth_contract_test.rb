require "test_helper"
require_relative "support/contract_fixtures"

class ApplicationOAuthContractTest < Minitest::Test
  def pack = CybrosAgentTest::ContractFixtures.pack("application_oauth.json")

  def client(body)
    @transport = CybrosAgentTest::FakeTransport.new([[200, {}, body]])
    CybrosAgent::ApplicationOAuth::Client.new(base_url: "https://nexus.example", transport: @transport)
  end

  def exchange(body)
    client(body).exchange_code(code: "fixture-code", redirect_uri: "http://127.0.0.1:49152/callback", code_verifier: "v" * 43)
  end

  def test_login_only_and_runtime_grants_have_independent_authority
    login = exchange(pack.fetch("valid_login_only_fixture"))
    assert login.platform_plane?
    refute login.member_plane?
    assert_nil login.agent
    assert_nil login.runner
    assert_equal pack.fetch("code_exchange_request"), @transport.requests.first.fetch(:form).transform_keys(&:to_s)

    connected = exchange(pack.fetch("valid_runtime_fixture"))
    assert connected.agent.member_plane?
    assert connected.agent.executor_plane?
    assert connected.runner.executor_plane?
    refute connected.runner.member_plane?
    refute_equal connected.refresh_token, connected.agent.refresh_token
    assert_equal "zz_unknown_value", exchange(pack.fetch("unknown_role_fixture")).user.role
  end

  def test_unknown_authorization_discriminators_are_rejected_without_retry
    %w[unknown_plane_fixture unknown_scope_fixture unknown_token_type_fixture unknown_child_plane_fixture].each do |name|
      assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { exchange(pack.fetch(name)) }
      assert_equal 1, @transport.requests.size
    end
  end

  def test_human_refresh_never_rotates_runtime_lineages
    refreshed = client(pack.fetch("valid_refresh_fixture")).rotate(refresh_token: "fixture-platform-refresh-token")
    assert_equal "fixture-rotated-platform-refresh-token", refreshed.refresh_token
    assert_nil refreshed.agent
    assert_nil refreshed.runner
    assert_equal pack.fetch("refresh_token_request"), @transport.requests.first.fetch(:form).transform_keys(&:to_s)
  end
end
