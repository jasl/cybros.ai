require "test_helper"
require_relative "../test_helpers/openapi_test_helper"

class OpenapiTest < ActionDispatch::IntegrationTest
  include OpenapiTestHelper

  test "the public description is OpenAPI 3.2 and reads no application data" do
    queries = []
    subscriber = ->(*args) { queries << args.last.fetch(:sql) unless args.last[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get "/openapi.json" }
    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal "3.2.0", response.parsed_body.fetch("openapi")
    assert_empty queries
  end

  test "every live HTTP API operation appears exactly once with its path parameters" do
    expected = Rails.application.routes.routes.flat_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      included = path.start_with?("/agent_api/v1/", "/api/v1/") ||
        %w[/oauth/device_authorization /oauth/device_authorization/cancellation /oauth/token /oauth/revoke].include?(path)
      next [] unless included && route.defaults[:action]

      path = path.gsub(/:(\w+)/, '{\1}')
      route.verb.split("|").map { |verb| "#{verb.downcase} #{path}" }
    end
    actual = openapi_document.fetch("paths").flat_map do |path, operations|
      operations.map do |verb, operation|
        parameters = operation.fetch("parameters", []).map { |parameter| openapi_resolve(parameter) }
        path_names = parameters.select { |parameter| parameter.fetch("in") == "path" }
        assert_equal path.scan(/\{(\w+)\}/).flatten.sort, path_names.map { |parameter| parameter.fetch("name") }.sort
        assert path_names.all? { |parameter| parameter.fetch("required") }
        assert operation.key?("security"), "#{verb} #{path} needs explicit authentication"
        assert operation.fetch("responses").keys.any? { |code| code.start_with?("2") }
        "#{verb} #{path}"
      end
    end
    assert_equal expected.sort, actual.sort
    ids = openapi_document.fetch("paths").values.flat_map { |operations| operations.values.map { |operation| operation.fetch("operationId") } }
    assert_equal ids.uniq, ids
  end

  test "authentication describes public endpoints and the three credential planes" do
    paths = openapi_document.fetch("paths")
    assert_empty paths.fetch("/api/v1/session").fetch("post").fetch("security")
    assert_empty paths.fetch("/oauth/token").fetch("post").fetch("security")
    assert_equal [{ "MemberBearer" => [] }], paths.fetch("/agent_api/v1/profile").fetch("get").fetch("security")
    assert_equal [{ "ExecutorBearer" => [] }], paths.fetch("/agent_api/v1/executor/inbox").fetch("get").fetch("security")
    assert_equal [{ "PlatformBearer" => [] }], paths.fetch("/api/v1/session").fetch("delete").fetch("security")
    assert_includes paths.fetch("/api/v1/profile/budgets").fetch("get").fetch("security"), { "BrowserSession" => [] }
    assert_equal [{ "MemberBearer" => [] }], paths.fetch("/agent_api/v1/profile/budgets").fetch("get").fetch("security")
  end

  test "response validation detects a missing required field" do
    schema = { "$ref" => "#/components/schemas/WorkspacesFullResponse" }
    fixture = Nexus::Contract.pack.fetch("workspaces.json").fetch("valid_full_fixture")
    assert_openapi_schema(schema, fixture)
    changed = Marshal.load(Marshal.dump(fixture))
    changed.fetch("workspace").delete("public_id")
    validator = JSONSchemer.schema(openapi_document).ref(schema.fetch("$ref"))
    assert_not validator.valid?(changed)
  end

  test "a deployment prefix belongs to the server URL rather than each path" do
    config = Rails.application.config
    previous = config.relative_url_root
    config.relative_url_root = "/nexus"
    document = Nexus::Openapi.build
    assert_equal "/nexus/", document.fetch(:servers).sole.fetch(:url)
    assert document.fetch(:paths).key?("/agent_api/v1/profile")
  ensure
    config.relative_url_root = previous
  end

  test "request examples match the public schemas" do
    [
      ["/agent_api/v1/workspaces", "post", "workspaces.json", "valid_create_request"],
      ["/agent_api/v1/workspaces/{public_id}", "patch", "workspaces.json", "valid_update_request"],
      ["/agent_api/v1/executor/announcement", "put", "executors.json", "announcement_request_fixture"],
      ["/agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules", "post", "schedules.json", "valid_create_request"],
      ["/agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules/{public_id}", "patch", "schedules.json", "valid_update_request"],
      ["/oauth/token", "post", "oauth.json", "device_token_request"],
      ["/oauth/token", "post", "application_oauth.json", "code_exchange_request"],
      ["/oauth/token", "post", "application_oauth.json", "refresh_token_request"],
    ].each do |path, verb, pack, key|
      assert_openapi_request Nexus::Contract.pack.fetch(pack).fetch(key), path: path, method: verb
    end
    assert_openapi_request({ "email" => "operator@example.com", "password" => "example-password" }, path: "/api/v1/session", method: "post")
  end

  test "uploads downloads and progress streams declare their media and headers" do
    paths = openapi_document.fetch("paths")
    upload = paths.fetch("/agent_api/v1/executor/uploads").fetch("post")
    assert openapi_resolve(upload.fetch("requestBody")).fetch("content").key?("multipart/form-data")
    bytes = paths.fetch("/agent_api/v1/uploads/{upload_public_id}/bytes").fetch("get")
    partial = openapi_resolve(bytes.fetch("responses").fetch("206"))
    assert partial.fetch("content").key?("*/*")
    assert partial.fetch("headers").key?("Content-Range")
    stream = paths.fetch("/api/v1/admin/deployment/upgrades/{upgrade_id}/stream").fetch("get")
    assert openapi_resolve(stream.fetch("responses").fetch("200")).fetch("content").key?("text/event-stream")
    claim = paths.fetch("/agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim").fetch("get")
    headers = claim.fetch("parameters").map { |parameter| openapi_resolve(parameter) }
    assert headers.any? { |parameter| parameter["name"] == "Claim-Token" && parameter["required"] }
    revoked = paths.fetch("/oauth/revoke").fetch("post")
    assert_not openapi_resolve(revoked.fetch("responses").fetch("200")).key?("content")
    removed = paths.fetch("/agent_api/v1/profile/prompt_documents/{slot}").fetch("delete")
    assert_not openapi_resolve(removed.fetch("responses").fetch("204")).key?("content")
  end
end
