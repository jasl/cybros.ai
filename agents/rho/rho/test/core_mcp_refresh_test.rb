require "test_helper"

class CoreMcpRefreshTest < Minitest::Test
  include RhoTest::CliHarness

  def test_refresh_names_one_server_through_the_daemon_and_keeps_publication_failures
    seen = []
    outcome = { "refreshed" => "rho.mcp", "failures" => [{ "message" => "platform unavailable" }],
      "server" => { "key" => "notes", "state" => "connected", "tools" => [] } }
    announce(endpoint: recording_routed_endpoint(seen, { "POST /mcp/refresh" => [[200, outcome]] }))
    assert_equal outcome, core.refresh_mcp("notes")
    body = seen.grep(%r{\APOST /mcp/refresh}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [{ "name" => "notes" }], body
  end

  def test_refused_refresh_is_not_retried
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /mcp/refresh" => [[503, { "error" => { "code" => "extension_refresh_failed", "message" => "old mount retained" } }]],
    }))
    error = assert_raises(Rho::Core::Refused) { core.refresh_mcp("notes") }
    assert_equal [503, "extension_refresh_failed", "old mount retained"], [error.status, error.code, error.message]
    assert_equal 1, seen.grep(%r{\APOST /mcp/refresh}).length
  end
end
