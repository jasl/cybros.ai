require "test_helper"
require_relative "support/contract_fixtures"

class TerminalLoginContractTest < Minitest::Test
  def setup
    @pack = CybrosAgentTest::ContractFixtures.pack("oauth.json")
    @authorization = @pack.fetch("valid_device_authorization_fixture")
  end

  def test_browser_approval_yields_an_api_session
    response = @pack.fetch("terminal_session_response")
    grant = request_session(response) do |authorization|
      assert_equal @authorization.fetch("user_code"), authorization.user_code
      assert_equal @authorization.fetch("verification_uri_complete"), authorization.verification_uri_complete
    end
    assert_equal @pack.fetch("terminal_authorization_request"), @transport.requests.first.fetch(:form).transform_keys(&:to_s)
    assert_equal "api", grant.session.kind
    assert_equal response.fetch("access_token"), grant.token
    refute_includes grant.inspect, grant.token
  end

  def test_terminal_rejects_other_credentials
    [@pack.fetch("valid_agent_token_fixture"), @pack.fetch("terminal_session_response").merge("refresh_token" => "surprise")].each do |response|
      assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { request_session(response) { } }
    end
  end

  private

    def request_session(response, &block)
      @transport = CybrosAgentTest::FakeTransport.new([[200, {}, @authorization], [200, {}, response]])
      sessions = CybrosAgent::Platform::Sessions.new(base_url: "https://nexus.example", transport: @transport)
      sessions.create_with_device(&block)
    end
end
