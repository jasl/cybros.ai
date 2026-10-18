require "test_helper"

class PlatformRetentionTest < Minitest::Test
  def test_read_update_and_disable_use_one_admin_resource
    transport = CybrosAgentTest::FakeTransport.new(
      [90, 30, nil].map { |days| [200, {}, { "account" => { "execution_details_retention_days" => days } }] }
    )
    context = CybrosAgent::PlatformClient.new(base_url: "https://nexus.example",
      credential: "platform-token", transport: transport).retention

    assert_equal 90, context.fetch.execution_details_retention_days
    assert_equal 30, context.update(execution_details_retention_days: 30).execution_details_retention_days
    assert_nil context.update(execution_details_retention_days: nil).execution_details_retention_days
    assert_equal ["/api/v1/admin/account/retention"] * 3, transport.requests.map { |row| row.fetch(:path) }
    assert_equal [:get, :patch, :patch], transport.requests.map { |row| row.fetch(:method) }
    assert_equal({ "account" => { "execution_details_retention_days" => nil } }, transport.requests.last.fetch(:body))
    assert_equal ["platform-token"] * 3, transport.requests.map { |row| row.fetch(:credential) }
  end

  def test_validation_failure_is_typed_and_not_retried
    transport = CybrosAgentTest::FakeTransport.new([[422, {}, { "error" => { "code" => "validation_failed" } }]])
    client = CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "platform-token", transport: transport)
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      client.retention.update(execution_details_retention_days: 0)
    end
    assert_equal "validation_failed", error.code
    assert_equal 1, transport.requests.length
  end

  def test_a_missing_setting_is_not_mistaken_for_disabled_collection
    transport = CybrosAgentTest::FakeTransport.new([[200, {}, { "account" => {} }]])
    client = CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "platform-token", transport: transport)
    assert_raises(CybrosAgent::Api::MalformedResponse) { client.retention.fetch }
  end
end
