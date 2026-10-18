require "test_helper"
require_relative "../../test_helpers/mcp_oauth_test_helper"

class McpConnections::OAuthTest < ActiveSupport::TestCase
  include McpOAuthTestHelper

  test "browser authorization survives reload and encrypts state PKCE and issued credentials" do
    with_oauth_server do |server|
      connection = create_oauth_connection(server)
      version = connection.lock_version
      result = start_oauth(connection)
      assert_predicate result, :success?
      assert_equal "pending", connection.reload.authorization_status
      query = URI.decode_www_form(URI.parse(result.authorization_url).query).to_h
      assert_equal "S256", query.fetch("code_challenge_method")
      assert_equal server.endpoint_url, query.fetch("resource")
      state = connection.oauth_data.pending_authorization.state
      verifier = connection.oauth_data.pending_authorization.envelope.fetch("code_verifier")
      raw = McpConnection.connection.select_value("SELECT oauth_data FROM mcp_connections WHERE id = #{connection.id}")
      [state, verifier, "synthetic-client"].each { |secret| refute_includes raw, secret }

      restored = McpConnection.find(connection.id)
      assert_predicate finish_oauth(restored, server, state: state), :success?
      assert_equal "authorized", restored.reload.authorization_status
      assert_equal "synthetic-access", restored.current_bearer_token
      assert_in_delta 1.hour.from_now, restored.authorization_expires_at, 5.seconds
      assert_equal version, restored.lock_version
      assert_nil restored.oauth_data.pending_authorization
      assert_nil restored.oauth_data.operation
      raw = McpConnection.connection.select_value("SELECT oauth_data FROM mcp_connections WHERE id = #{connection.id}")
      %w[synthetic-access synthetic-refresh].each { |secret| refute_includes raw, secret }
      form = URI.decode_www_form(token_requests(server).sole.fetch(:body)).to_h
      assert_equal verifier, form.fetch("code_verifier")
      assert_equal server.endpoint_url, form.fetch("resource")
      assert_equal "authorization_code", form.fetch("grant_type")

      count = server.requests.size
      assert_equal "authorized", restored.authorization_status
      assert restored.credential_configured?
      assert_equal count, server.requests.size
      refute_predicate finish_oauth(restored, server, state: state), :success?
      assert_equal 1, token_requests(server).size
    end
  end

  test "wrong state and issuer do not spend the pending grant" do
    with_oauth_server do |server|
      connection = create_oauth_connection(server)
      assert_predicate start_oauth(connection), :success?
      state = connection.reload.oauth_data.pending_authorization.state
      refute_predicate finish_oauth(connection, server, state: "wrong-state"), :success?
      refute_predicate finish_oauth(connection, server, state: state, iss: "https://wrong.example.test"), :success?
      assert_empty token_requests(server)
      assert_equal state, connection.reload.oauth_data.pending_authorization.state
      assert_nil connection.oauth_data.operation
      assert_predicate finish_oauth(connection, server, state: state), :success?
      assert_equal 1, token_requests(server).size
    end
  end

  test "the MCP challenge discovers custom resource metadata and selects its requested scope" do
    with_oauth_server(challenge: true) do |server|
      connection = create_oauth_connection(server)
      result = start_oauth(connection)
      assert_predicate result, :success?
      query = URI.decode_www_form(URI.parse(result.authorization_url).query).to_h
      assert_equal "challenge:read", query.fetch("scope")
      assert server.requests.any? { |request| request.fetch(:line).start_with?("GET /authorization-resource ") }
      assert_predicate finish_oauth(connection, server), :success?
      expire_oauth(connection)
      assert_predicate McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2), :success?
      assert_equal 2, token_requests(server).size
      probes = server.requests.select { |request| request.fetch(:line).start_with?("GET /mcp ") }
      assert_equal 2, probes.size
      assert probes.none? { |request| request.fetch(:headers).key?("authorization") }
    end
  end

  test "unavailable authorization metadata preserves an unspent refresh token for a later attempt" do
    unavailable = false
    metadata = -> { unavailable ? { status: 503, json: { error: "temporarily_unavailable" } } : nil }
    with_oauth_server(metadata_response: metadata) do |server|
      connection = create_oauth_connection(server)
      authorize_oauth(connection, server)
      expire_oauth(connection)
      unavailable = true
      refute_predicate McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2), :success?
      assert_equal "synthetic-refresh", connection.reload.oauth_data.tokens.fetch("refresh_token")
      assert_nil connection.oauth_data.operation
      assert_equal "authorized", connection.authorization_status
      assert_equal 1, token_requests(server).size
      unavailable = false
      assert_predicate McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2), :success?
      assert_equal 2, token_requests(server).size
    end
  end

  test "refresh preserves an omitted refresh token and publishes rotation without a management version change" do
    response = ->(form) {
      if form.fetch("grant_type") == "refresh_token"
        assert_equal "synthetic-refresh", form.fetch("refresh_token")
        { json: { access_token: "refreshed-access", token_type: "bearer", expires_in: 1800 } }
      else
        { json: { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 3600 } }
      end
    }
    with_oauth_server(token_response: response) do |server|
      connection = create_oauth_connection(server)
      authorize_oauth(connection, server)
      expire_oauth(connection)
      version = connection.lock_version
      result = McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2)
      assert_predicate result, :success?
      assert_equal "refreshed-access", result.bearer_token
      assert_equal "synthetic-refresh", connection.reload.oauth_data.tokens.fetch("refresh_token")
      assert_equal "Bearer", connection.oauth_data.tokens.fetch("token_type")
      assert_equal version, connection.lock_version
      assert_equal 2, token_requests(server).size
    end
  end

  test "a rejected refresh response discards the possibly spent old token and is never replayed" do
    response = ->(form) {
      if form.fetch("grant_type") == "refresh_token"
        { json: { access_token: "bad\nheader", refresh_token: "rotated-refresh", token_type: "Bearer", expires_in: 3600 } }
      else
        { json: { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 3600 } }
      end
    }
    with_oauth_server(token_response: response) do |server|
      connection = create_oauth_connection(server)
      authorize_oauth(connection, server)
      expire_oauth(connection)
      2.times do
        result = McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2)
        refute_predicate result, :success?
      end
      assert_equal "reauthorization_required", connection.reload.authorization_status
      assert_nil connection.oauth_data.tokens
      assert_equal 2, token_requests(server).size
    end
  end

  test "a disconnected code exchange consumes the grant before sending and cannot be retried" do
    with_oauth_server(token_response: ->(_form) { nil }) do |server|
      connection = create_oauth_connection(server)
      assert_predicate start_oauth(connection), :success?
      state = connection.reload.oauth_data.pending_authorization.state
      2.times { refute_predicate finish_oauth(connection, server, state: state), :success? }
      assert_equal "reauthorization_required", connection.reload.authorization_status
      assert_nil connection.oauth_data.pending_authorization
      assert_nil connection.oauth_data.tokens
      assert_equal 1, token_requests(server).size
    end
  end

  test "an oversized refresh envelope fails without exposing upstream data or retaining its spent token" do
    response = ->(form) {
      tokens = { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 3600 }
      tokens[:extra] = "private-upstream-data" * 4000 if form.fetch("grant_type") == "refresh_token"
      { json: tokens }
    }
    with_oauth_server(token_response: response) do |server|
      connection = create_oauth_connection(server)
      authorize_oauth(connection, server)
      expire_oauth(connection)
      result = McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2)
      assert_equal :authorization_failed, result.outcome
      assert_equal "reauthorization_required", connection.reload.authorization_status
      assert_nil connection.oauth_data.tokens
      assert_nil connection.oauth_data.operation
      assert_equal 2, token_requests(server).size
      refute_includes result.to_h.except(:connection).to_json, "private-upstream-data"
    end
  end

  test "a token with no expiry remains usable and expired tokens without refresh require authorization" do
    with_oauth_server(token_response: ->(_form) { { json: { access_token: "synthetic-access", token_type: "Bearer" } } }) do |server|
      connection = create_oauth_connection(server)
      authorize_oauth(connection, server)
      assert_nil connection.authorization_expires_at
      assert_predicate McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2), :success?
      expire_oauth(connection)
      refute_predicate McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2), :success?
      assert_equal "reauthorization_required", connection.reload.authorization_status
      assert_equal 1, token_requests(server).size
    end
  end

  test "an abandoned refresh becomes reauthorization required without replaying its old token" do
    with_oauth_server do |server|
      connection = create_oauth_connection(server)
      authorize_oauth(connection, server)
      expire_oauth(connection)
      assert_equal :refresh_required, connection.prepare_oauth_credential.outcome
      operation = connection.oauth_data.operation
      staged = McpConnection::OAuthData.new(connection.oauth_data.as_json)
      travel_to(operation.deadline_at + 1.second) do
        refute_predicate McpConnections::OAuth::Credential.call(connection: connection, timeout_seconds: 2), :success?
        refute_predicate connection.complete_oauth_operation(operation_id: operation.id, data: staged), :success?
      end
      assert_equal "reauthorization_required", connection.reload.authorization_status
      assert_equal 1, token_requests(server).size
    end
  end

  test "disable disconnect and a replacement authorization fence late operation publication" do
    with_oauth_server do |server|
      connection = create_oauth_connection(server)
      authorize_oauth(connection, server)
      expire_oauth(connection)
      assert_equal :refresh_required, connection.prepare_oauth_credential.outcome
      old = McpConnection::OAuthData.new(connection.oauth_data.as_json)
      assert_predicate connection.revise(attributes: { enabled: false }, expected_lock_version: connection.lock_version), :success?
      assert_predicate connection.revise(attributes: { enabled: true }, expected_lock_version: connection.lock_version), :success?
      refute_predicate connection.complete_oauth_operation(operation_id: old.operation.id, data: old), :success?
      assert_equal "reauthorization_required", connection.reload.authorization_status

      assert_predicate start_oauth(connection), :success?
      state = connection.reload.oauth_data.pending_authorization.state
      assert_predicate connection.set_credential(bearer_token: nil, expected_lock_version: connection.lock_version), :success?
      refute_predicate finish_oauth(connection, server, state: state), :success?
      assert_equal "not_authorized", connection.reload.authorization_status
      assert_predicate start_oauth(connection), :success?
      refute_predicate finish_oauth(connection, server, state: state), :success?
      assert_equal 1, token_requests(server).size
    end
  end

  test "token response fields are validated once before installation" do
    [{ "access_token" => "" }, { "access_token" => "bad\rheader" }, { "token_type" => "MAC" },
      { "refresh_token" => "" }, { "expires_in" => -1 }, { "expires_in" => 0 },
      { "expires_in" => "infinite" }, { "expires_in" => 1e300 }].each do |invalid|
      data = McpConnection::OAuthData.new(tokens: { "access_token" => "synthetic-access", "token_type" => "Bearer" }.merge(invalid))
      assert_raises(Mcp::Error) { McpConnections::OAuth::TokenResponse.apply(data) }
    end
  end

  test "removing and restoring the Human cannot revive an earlier browser authorization" do
    with_oauth_server do |server|
      connection = create_oauth_connection(server)
      assert_predicate start_oauth(connection), :success?
      state = connection.reload.oauth_data.pending_authorization.state
      assert_equal :removed, connection.owner.remove
      assert_equal :restored, connection.owner.restore
      connection.reload
      assert_predicate connection.revise(attributes: { enabled: true }, expected_lock_version: connection.lock_version), :success?
      refute_predicate finish_oauth(connection, server, state: state), :success?
      assert_equal "reauthorization_required", connection.reload.authorization_status
      assert_empty token_requests(server)
    end
  end
end
