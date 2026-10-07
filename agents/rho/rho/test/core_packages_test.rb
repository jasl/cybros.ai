require "test_helper"

class CorePackagesTest < Minitest::Test
  include RhoTest::CliHarness

  def test_named_package_operations_use_one_authenticated_daemon_request_and_keep_publication_warnings
    seen = []
    listed = { "packages" => [{ "name" => "notes", "active" => true }] }
    applied = { "action" => "activate", "name" => "notes", "warning" => "catalog published; durability uncertain" }
    announce(endpoint: recording_routed_endpoint(seen, {
      "GET /extensions/packages" => [[200, listed]],
      "POST /extensions/packages" => [[200, applied]],
    }))
    assert_equal listed, core.packages
    assert_equal applied, core.manage_package(action: "activate", name: "notes", version: "a" * 64, configuration: { "prefix" => "hello" })
    body = seen.grep(%r{\APOST /extensions/packages}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [{ "action" => "activate", "name" => "notes", "version" => "a" * 64, "configuration" => { "prefix" => "hello" } }], body
  end

  def test_package_failure_is_typed_and_never_retried
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /extensions/packages" => [[422, { "error" => { "code" => "package_refused", "message" => "old selection retained" } }]],
    }))
    error = assert_raises(Rho::Core::Refused) { core.manage_package(action: "rollback", name: "notes") }
    assert_equal [422, "package_refused", "old selection retained"], [error.status, error.code, error.message]
    assert_equal 1, seen.grep(%r{\APOST /extensions/packages}).length
  end
end
