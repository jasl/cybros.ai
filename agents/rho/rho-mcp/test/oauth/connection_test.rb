require "test_helper"
require "support/oauth_world"

# THE DAEMON'S PATH against the real
# fixture with a real credential file: the provider attached only with
# tokens held; the refresh transparent under a call; a transient renewal
# failure the http row's unreachable path with the tokens intact; a
# rejected refresh the login sentence and the record; a step-up the union
# sentence and a `pending_scope` refused from the file; a login performed
# meanwhile the reconnect notice; a credential file rho refuses to read
# its own kind; two calls on a logged-in row serialized.
class OauthConnectionTest < Minitest::Test
  include McpTest::OauthWorld
  include McpTest::Helpers

  LOGIN_SENTENCE = "mcp server fxo: authentication required — its authorization was rejected and this process cannot " \
                   "log in; ask the person to run `rho mcp login fxo`; every call to mcp__fxo__* fails until then".freeze

  def setup = oauth_setup
  def teardown = oauth_teardown

  def logged_in_connection
    login!
    connection.tap(&:open!)
  end

  # The fixture's door: every live access token expired at once (no clock).
  def expire! = switch!("expire")

  def test_the_provider_rides_only_with_tokens_and_the_bearer_is_on_the_wire
    connection = logged_in_connection
    assert_predicate connection, :connected?
    assert_equal :logged_in, connection.auth_status.state
    assert_equal "hello", call(connection, "echo", { "text" => "hello" }).content
    access = document.dig("tokens", "access_token")
    assert_includes issued.fetch("authorization_headers"), "Bearer #{access}", "the stored token rode as the header"
    assert_equal 0, issued.fetch("refreshes")
  end

  def test_the_refresh_under_a_call_is_transparent_and_the_rotated_pair_is_stored_and_redacted
    connection = logged_in_connection
    before = document
    expire!
    result = call(connection, "echo", { "text" => "the token is #{before.dig("tokens", "access_token")}" })
    assert_equal "the token is •••", result.content, "the previous access token, now rotated, is erased by the live set"
    refute_match(/\Anote:/, result.content, "no notice: the model sees nothing")
    assert_equal 1, issued.fetch("refreshes")
    after = document
    refute_equal before.dig("tokens", "access_token"), after.dig("tokens", "access_token")
    refute_equal before.dig("tokens", "refresh_token"), after.dig("tokens", "refresh_token")
    assert_includes @log, [:info, "mcp.oauth.refreshed", { server: "fxo" }]
    assert_equal({ "grant_type" => "refresh_token", "resource" => "#{@base}/mcp" }, issued.fetch("token_requests").last,
      "the refresh carried the resource (RFC 8707), and the record holds no token value")
    refute(@log.any? { |entry| entry[1] == "mcp.oauth.login_required" })
    assert_nil connection.down
    redact = Rho::Runner::Redact.new(@row.secrets, live: @storage)
    assert_equal "old ••• new •••", redact.call("old #{before.dig("tokens", "refresh_token")} new #{after.dig("tokens", "access_token")}")
  end

  # The refresh token was kept (the gem's own classification of a 503), so
  # this is a renewal failure the next call retries — never a login.
  def test_a_transient_renewal_failure_is_unreachable_with_the_tokens_intact_and_the_next_call_reconnects
    connection = logged_in_connection
    switch!("token_outage", "on")
    expire!
    error = assert_raises(Rho::Mcp::ServerGone) { call(connection, "echo", { "text" => "x" }) }
    assert_equal "mcp server fxo stopped answering during mcp__fxo__echo: could not renew its authorization (the " \
                 "authorization server did not accept the refresh; the refresh token is kept); the next call reconnects",
      error.message
    assert_equal "unreachable (could not renew its authorization (the authorization server did not accept the refresh; " \
                 "the refresh token is kept)) at 08:00:00", connection.down
    assert_includes @log.map { |e| e[0..1] }, [:warn, "mcp.oauth.renewal_failed"]
    refute(@log.any? { |entry| entry[1] == "mcp.oauth.login_required" })
    assert_match(/\Art-/, document.dig("tokens", "refresh_token"), "the refresh token is intact")
    assert_equal :logged_in, connection.auth_status.state

    switch!("token_outage", "off")
    result = call(connection, "echo", { "text" => "back" })
    assert_match(/\Anote: mcp server fxo had stopped answering \(.*\) and was reconnected for this call; any state it held is gone\nback\z/,
      result.content)
    assert_equal 1, issued.fetch("refreshes")
    assert_nil connection.down
  end

  def test_a_rejected_refresh_is_the_login_sentence_the_record_and_the_log_line_and_the_next_call_reads_the_file_only
    connection = logged_in_connection
    switch!("revoke")
    error = assert_raises(Rho::Mcp::CallRefused) { call(connection, "echo", { "text" => "x" }) }
    assert_equal LOGIN_SENTENCE, error.message
    assert_equal "needs login — run `rho mcp login fxo`", connection.down
    refute_predicate connection, :connected?
    assert_includes @log, [:warn, "mcp.oauth.login_required", { server: "fxo", tool: "mcp__fxo__echo", reason: "tokens cleared (the refresh was rejected)" }]
    written = document
    refute written.key?("tokens"), "the gem's invalid_grant arm cleared them"
    assert_equal "dcr-1", written.dig("client_information", "client_id"), "the registration is kept"
    assert_equal :needs_login, connection.auth_status.state

    reads = issued.fetch("prm_reads")
    error = assert_raises(Rho::Mcp::CallRefused) { call(connection, "echo", { "text" => "y" }) }
    assert_equal LOGIN_SENTENCE, error.message
    assert_equal reads, issued.fetch("prm_reads"), "the file-first revive: no network"
    assert_equal 1, issued.fetch("registrations")
  end

  def test_a_login_performed_meanwhile_recovers_at_the_next_call_with_the_notice
    connection = logged_in_connection
    switch!("revoke")
    assert_raises(Rho::Mcp::CallRefused) { call(connection, "echo", { "text" => "x" }) }
    switch!("revoke", "off")
    login!
    assert_equal 1, issued.fetch("registrations"), "the stored registration reused"
    result = call(connection, "echo", { "text" => "again" })
    assert_equal "note: mcp server fxo had needed a login and was reconnected for this call; any state it held is gone\nagain",
      result.content
    assert_includes @log, [:info, "mcp.server_restarted", { server: "fxo", tool: "mcp__fxo__echo", after: :login_required }]
    assert_predicate connection, :connected?
  end

  def test_a_step_up_is_the_union_sentence_and_a_pending_scope_refused_from_the_file_until_the_login_sends_it
    connection = logged_in_connection
    switch!("require_scope", "fx:write")
    error = assert_raises(Rho::Mcp::CallRefused) { call(connection, "echo", { "text" => "x" }) }
    assert_equal "mcp server fxo: authentication required — it now requires scope fx:write (granted: fx:read) and this " \
                 "process cannot log in; ask the person to run `rho mcp login fxo` (which asks for fx:read fx:write); " \
                 "every call to mcp__fxo__* fails until then", error.message
    assert_equal "fx:read fx:write", @storage.pending_scope
    assert_match(/\Aat-/, document.dig("tokens", "access_token"), "the tokens are valid and kept")
    assert_includes @log, [:warn, "mcp.oauth.login_required", { server: "fxo", tool: "mcp__fxo__echo", reason: "scope step-up (fx:read fx:write)" }]
    assert_equal "the server now requires scope fx:write; the login asks for fx:read fx:write", connection.auth_status.reason
    assert_equal 1, issued.fetch("registrations"), "no new registration"

    reads = issued.fetch("prm_reads")
    assert_raises(Rho::Mcp::CallRefused) { call(connection, "echo", { "text" => "y" }) }
    assert_equal reads, issued.fetch("prm_reads")

    login!
    assert_equal "fx:read fx:write", issued.dig("authorize", "scope")
    assert_nil @storage.pending_scope
    result = call(connection, "echo", { "text" => "wide" })
    assert_match(/\Anote: mcp server fxo had needed a login and was reconnected for this call; any state it held is gone\nwide\z/,
      result.content)
  end

  def test_a_credential_file_rho_refuses_to_read_is_its_own_kind_under_a_call_and_at_open
    connection = logged_in_connection
    File.chmod(0o644, credential_path)
    error = assert_raises(Rho::Mcp::CallRefused) { call(connection, "echo", { "text" => "x" }) }
    assert_equal "mcp server fxo: credential file mcp/credentials/fxo.json must be private (mode 0600), got 0644 — ask the " \
                 "person to chmod it; every call to mcp__fxo__* fails until then", error.message
    assert_equal "credential file mcp/credentials/fxo.json must be private (mode 0600), got 0644 — rho refuses to read it",
      connection.down
    assert_includes @log, [:error, "mcp.oauth.credential_file", { server: "fxo", reason: "credential file mcp/credentials/fxo.json must be private (mode 0600), got 0644" }]
    refute(@log.any? { |entry| entry[1] == "mcp.oauth.login_required" }, "never spelled needs login")
    assert_raises(Rho::Mcp::CallRefused) { call(connection, "echo", { "text" => "y" }) }

    fresh = connection()
    error = assert_raises(Rho::Mcp::Unavailable) { fresh.open! }
    assert_equal "credential file mcp/credentials/fxo.json must be private (mode 0600), got 0644 — rho refuses to read it",
      error.message
    assert_equal :credential_file, fresh.auth_status.state

    File.chmod(0o600, credential_path)
    result = call(connection, "echo", { "text" => "fixed" })
    assert_match(/\Anote: mcp server fxo had refused its credential file \(.*\) and was reconnected for this call; any state it held is gone\nfixed\z/,
      result.content)
  end

  # Two calls in flight on a logged-in row meet one expired token: serialized,
  # the second finds the first's rotated pair — one refresh, both answered.
  # The token endpoint HOLDS (`slow_token`) so the two are in flight
  # together: without the mutex both would present the same refresh token
  # and the second, rotated away, would log the row out.
  def test_two_concurrent_calls_on_a_logged_in_row_are_serialized_and_spend_one_refresh
    connection = logged_in_connection
    switch!("slow_token", "on")
    expire!
    threads = 2.times.map { |i| Thread.new { call(connection, "echo", { "text" => "call #{i}" }) } }
    answers = threads.map { |thread| thread.value.content }
    assert_equal ["call 0", "call 1"], answers.sort
    assert_equal 1, issued.fetch("refreshes")
  end

  def test_a_row_holding_no_tokens_keeps_the_http_fan
    connection = connection(storage: nil, row: oauth_row(key: "plain", url: "#{@base}/open"))
    fixture = @fixture
    @fixture.define_singleton_method(:call) do |env|
      env["PATH_INFO"] == "/open" ? fixture.instance_variable_get(:@transport).call(env) : super(env)
    end
    connection.open!
    assert_equal false, connection.send(:serialized) { connection.instance_variable_get(:@mutex).owned? }
    logged_in = logged_in_connection
    assert_equal true, logged_in.send(:serialized) { logged_in.instance_variable_get(:@mutex).owned? }
  end
end
