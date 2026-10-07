require "test_helper"
require "support/oauth_world"

# THE VERB: the three phases against the mock
# AS + RS with the suite's browser and, separately, the paste; a server
# that answers anonymously but publishes an authorization server is
# logged in to (the optional-authorization shape) and one that publishes
# nothing is nothing to log in to; a launcher that did not start is said
# once and the wait goes on; a recorded `pending_scope` sent; a wrong
# `state` and a wrong `iss` fail with nothing stored — the `iss` compared
# BEFORE any server-sent error is quoted; an `error` answer is the
# listener's sentence; a logout unlinks the file whole.
class OauthLoginTest < Minitest::Test
  include McpTest::OauthWorld
  include McpTest::Helpers

  NOTHING_TO_LOG_IN_TO = "answered without asking for authorization and publishes no authorization server — nothing to " \
                         "log in to (an open server, or one your headers already satisfy)".freeze
  BROWSER_FALLBACK = "the browser did not open — open the URL above by hand; rho keeps waiting for the redirect to its " \
                     "loopback callback".freeze

  def setup = oauth_setup
  def teardown = oauth_teardown

  def test_the_three_phases_log_in_store_the_pair_and_prove_on_the_read_only_view
    cli = login!
    lines = cli.out.string.lines.map(&:chomp)
    assert_equal "authorizing with #{@base}/oauth for scopes fx:read (resource #{@base}/mcp)", lines.fetch(0),
      "the challenge's fx:read won over PRM's fx:read fx:write"
    assert_match(%r{\Aopen this URL to authorize rho: #{Regexp.escape(@base)}/oauth/authorize\?}, lines.fetch(1))
    assert_equal "logged in to fxo (issuer #{@base}/oauth; scope fx:read; 2 tools listed; refresh token held)", lines.fetch(2)
    assert_equal "no daemon running; fxo's tools will be announced at the next boot", lines.fetch(3)
    assert_equal 4, lines.length

    authorize = URI.decode_www_form(URI(lines.fetch(1).split(": ", 2).last).query).to_h
    assert_equal "S256", authorize.fetch("code_challenge_method")
    assert_equal "#{@base}/mcp", authorize.fetch("resource")
    assert_match(%r{\Ahttp://127\.0\.0\.1:\d+/callback\z}, authorize.fetch("redirect_uri"))
    refute_empty authorize.fetch("state")
    registration = issued.fetch("registration")
    assert_equal ["http://127.0.0.1/callback", authorize.fetch("redirect_uri")], registration.fetch("redirect_uris"),
      "both loopback forms registered"
    assert_equal "native", registration.fetch("application_type")
    assert_equal [1, 1, true], issued.values_at("registrations", "authorizations", "token_resource_seen")

    written = document
    assert_equal "#{@base}/mcp", written.fetch("url")
    assert_equal "#{@base}/oauth", written.dig("client_information", "issuer")
    assert_equal "dcr-1", written.dig("client_information", "client_id")
    assert_match(/\Art-/, written.dig("tokens", "refresh_token"))
    assert_equal "fx:read", written.dig("tokens", "scope")
    assert_equal "2027-01-15T08:00:00Z", written.fetch("issued_at")
    refute written.key?("optional"), "the server asked for the login: no optional mark"
    refute @storage.status.optional
    assert_equal "0600", format("%04o", File.stat(credential_path).mode & 0o777)
    refute_includes cli.out.string, written.dig("tokens", "access_token"), "no token on the terminal"
    assert_equal 0, issued.fetch("refreshes"), "the proof spent no refresh"
  end

  def test_no_browser_prints_the_url_and_takes_the_pasted_redirect
    reader, writer = IO.pipe
    out = StringIO.new
    cli = self.cli
    cli.out = out
    verb = Thread.new { login!(options: { "no-browser": true }, browser: ->(_url) { flunk "the browser was launched" }, input: reader, cli: cli) }
    url = await(seconds: 10) { out.string[/open this URL to authorize rho: (\S+)/, 1] }
    refute_nil url, "the URL was printed"
    location = Net::HTTP.get_response(URI(url))["location"]
    writer.puts location
    verb.join(10)
    assert_includes out.string, "logged in to fxo (issuer #{@base}/oauth; scope fx:read; 2 tools listed; refresh token held)\n"
  ensure
    writer&.close
    reader&.close
  end

  # THE URL A PERSON MUST OPEN:
  # the gem draws `state` and the PKCE verifier at random, and a draw
  # that happens to spell `sk-…` is still the one the authorization
  # server will check — so the printed URL passes the ONE escaper and the
  # row's value redaction, never the SDK's family pattern; the URL the
  # browser is handed and the one printed are the same bytes.
  def test_the_printed_authorization_url_is_never_family_redacted
    draw = SecureRandom.method(:urlsafe_base64)
    # The gem draws `state` as `urlsafe_base64(32)`: that draw, and only
    # that one, spells a family prefix for the length of the login.
    SecureRandom.define_singleton_method(:urlsafe_base64) do |n = 16, padding = false|
      n == 32 ? "sk-#{draw.call(30, padding)}" : draw.call(n, padding)
    end
    opened = []
    begin
      cli = login!(browser: ->(url) { opened << url; follow(url) })
    ensure
      SecureRandom.singleton_class.remove_method(:urlsafe_base64)
    end
    line = cli.out.string.lines.fetch(1).chomp
    url = line.delete_prefix("open this URL to authorize rho: ")
    refute_includes line, "[REDACTED]", line
    assert_equal [url], opened, "the printed URL is the browser's, byte for byte"
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    assert_match(/\Ask-/, state, "the draw that spells a family prefix rode through")
    assert_equal state, issued.dig("authorize", "state"), "the authorization server checked that state"
    assert_match(/\Alogged in to fxo/, cli.out.string.lines.fetch(2))
  end

  # THE PRE-REGISTERED CLIENT: the login registers
  # nothing and authorizes under the configured id — the storage's overlay
  # answers it, the file keeps the issuer stamp alone (storage_test's rule).
  def test_a_configured_client_id_registers_nothing
    row = oauth_row(oauth: { "client_id" => "rho-at-acme" })
    storage = storage_for(row)
    cli = login!(row: row, storage: storage)
    assert_match(/\Alogged in to fxo /, cli.out.string.lines.fetch(2))
    assert_equal [0, 1], issued.values_at("registrations", "authorizations")
    assert_equal "rho-at-acme", issued.dig("authorize", "client_id")
    assert_equal "rho-at-acme", storage.client_information["client_id"]
    assert_equal({ "issuer" => "#{@base}/oauth" }, document.fetch("client_information"), "the file holds the stamp, never the id")
    assert_equal 0, issued.fetch("refreshes")
  end

  def test_a_server_that_never_401s_and_publishes_nothing_is_nothing_to_log_in_to
    open = oauth_row(key: "open", url: "#{@base}/open")
    fixture = @fixture
    @fixture.define_singleton_method(:call) do |env|
      env["PATH_INFO"] == "/open" ? fixture.instance_variable_get(:@transport).call(env) : super(env)
    end
    cli = login!(row: open, storage: storage_for(open))
    assert_equal "open #{NOTHING_TO_LOG_IN_TO}\n", cli.out.string
    assert_equal 0, issued.fetch("authorizations")
  end

  # THE OPTIONAL-AUTHORIZATION SHAPE (the spec's "authorization is
  # OPTIONAL"; `authorization-server-discovery.mdx`'s well-known fallback):
  # the anonymous initialize is answered, so no 401 classifies anything —
  # the verb reads the protected-resource metadata the server publishes
  # (the GET's hint, then the path-aware well-known, then the root) and a
  # published authorization server makes the server loggable: the same
  # flow, the scope from the GET's challenge, the proof and every later
  # call carrying the token a server that took anonymous calls now reads.
  def test_a_server_that_answers_anonymously_but_publishes_an_authorization_server_is_logged_in_to
    switch!("optional")
    cli = login!
    lines = cli.out.string.lines.map(&:chomp)
    assert_equal "authorizing with #{@base}/oauth for scopes fx:read (resource #{@base}/mcp)", lines.fetch(0),
      "the GET's challenge scope rode into the consent line"
    assert_match(%r{\Aopen this URL to authorize rho: #{Regexp.escape(@base)}/oauth/authorize\?}, lines.fetch(1))
    assert_equal "logged in to fxo (issuer #{@base}/oauth; scope fx:read; 2 tools listed; refresh token held) — " \
                 "authorization is optional here: the server answered anonymously too, and every call carries the token " \
                 "from now on", lines.fetch(2)
    assert_equal 4, lines.length
    assert_operator issued.fetch("anonymous"), :>, 0, "the probe's initialize went through untokened"
    assert_equal [2, 1, 1], issued.values_at("prm_reads", "registrations", "authorizations"),
      "the document read twice — the verb's probe, then the flow at the URL the probe handed it"
    access = document.dig("tokens", "access_token")
    assert_includes issued.fetch("authorization_headers"), "Bearer #{access}", "the proof sent the token"
    assert_equal true, document.fetch("optional"), "the store records that the authorization is optional"
    assert @storage.status.optional

    anonymous = issued.fetch("anonymous")
    connection = connection()
    connection.open!
    assert_equal :logged_in, connection.auth_status.state
    assert connection.auth_status.optional, "the daemon's report carries the mark"
    assert_equal "hello", call(connection, "echo", { "text" => "hello" }).content
    assert_equal anonymous, issued.fetch("anonymous"), "a logged-in row sends the bearer on every call"
    assert_equal 0, issued.fetch("refreshes")
  end

  def test_a_server_that_answers_anonymously_and_publishes_nothing_keeps_the_refusal
    switch!("optional")
    switch!("no_prm")
    cli = login!
    assert_equal "fxo #{NOTHING_TO_LOG_IN_TO}\n", cli.out.string
    assert_equal [0, 0], issued.values_at("registrations", "authorizations")
    refute File.exist?(credential_path)
  end

  # THE LAUNCHER THAT DID NOT START (no `open`, no `xdg-open`, no
  # `$BROWSER`, a spawn that failed): the URL is on screen already, one
  # line says the browser did not open, and the verb keeps waiting on the
  # loopback — never fatal. The suite's launcher answers false and opens
  # the URL from a thread, as the person would by hand.
  def test_a_launcher_that_did_not_start_is_said_once_and_the_login_completes_by_hand
    by_hand = nil
    cli = login!(browser: ->(url) { by_hand = Thread.new { sleep 0.1; follow(url) }; false })
    by_hand&.join(10)
    lines = cli.out.string.lines.map(&:chomp)
    assert_match(/\Aopen this URL to authorize rho: /, lines.fetch(1))
    assert_equal BROWSER_FALLBACK, lines.fetch(2)
    assert_match(/\Alogged in to fxo /, lines.fetch(3))
    assert_equal 5, lines.length
  end

  def test_a_recorded_pending_scope_is_the_one_scope_sent_and_cleared_on_success
    login!
    @storage.record_pending_scope(%w[fx:read fx:write])
    cli = login!
    assert_equal "authorizing with #{@base}/oauth for scopes fx:read fx:write (resource #{@base}/mcp)", cli.out.string.lines.first.chomp
    assert_equal "fx:read fx:write", issued.dig("authorize", "scope")
    assert_nil @storage.pending_scope
    assert_equal "fx:read fx:write", document.dig("tokens", "scope")
    assert_equal 1, issued.fetch("registrations"), "the stored registration was reused"
    assert_equal 2, issued.fetch("authorizations")
  end

  def test_a_wrong_state_fails_the_login_with_nothing_stored
    switch!("tamper_state")
    error = assert_raises(Rho::Error) { login! }
    assert_equal "OAuth state mismatch (CSRF protection)", error.message
    refute File.exist?(credential_path) && document.key?("tokens"), "the code was never exchanged"
    assert_equal 0, issued.fetch("refreshes")
  end

  def test_a_wrong_iss_fails_the_login_before_the_exchange
    switch!("tamper_iss")
    error = assert_raises(Rho::Error) { login! }
    assert_equal iss_mismatch, error.message
    refute(File.exist?(credential_path) && document.key?("tokens"))
    refute issued.fetch("token_resource_seen"), "the code was never exchanged"
  end

  # the `iss` is compared BEFORE any server-sent error is quoted — a redirect from the
  # wrong issuer carrying `error=access_denied` names the mismatch alone, never the text
  # an impostor chose.
  def test_a_denial_from_the_wrong_issuer_names_the_iss_mismatch_only
    switch!("deny")
    switch!("tamper_iss")
    error = assert_raises(Rho::Error) { login! }
    assert_equal iss_mismatch, error.message
    refute_includes error.message, "access_denied"
    refute_includes error.message, "the person said no"
    refute(File.exist?(credential_path) && document.key?("tokens"))
  end

  def iss_mismatch
    "fxo's authorization response named issuer `#{@base}/other`, not the authorization server rho sent you to " \
      "(`#{@base}/oauth`) — RFC 9207 `iss` mismatch; nothing was exchanged"
  end

  def test_a_denied_consent_is_the_listeners_sentence_not_the_gems
    switch!("deny")
    error = assert_raises(Rho::Error) { login! }
    assert_equal "fxo's authorization server answered `access_denied`: the person said no <b>", error.message
  end

  # A hostile or sloppy AS answers `error_description` carrying a
  # terminal-title escape: the sentence shows the bytes as the probe shows
  # a server's — the ONE escaper — never as the terminal would obey them.
  def test_a_denials_description_reaches_the_terminal_escaped
    switch!("deny", "the person said \e]0;x\a no")
    error = assert_raises(Rho::Error) { login! }
    assert_equal "fxo's authorization server answered `access_denied`: the person said \\u{1B}]0;x\\u{7} no", error.message
    refute_includes error.message, "\e"
  end

  def test_a_callback_that_never_arrives_names_the_deadline
    listener = Rho::Mcp::Oauth::Callback.new(seconds: 0.2)
    error = assert_raises(Rho::Error) { login!(browser: ->(_url) { nil }, callback: listener) }
    assert_equal "no authorization callback arrived within 5 minutes — run `rho mcp login fxo` again", error.message
  end

  def test_a_no_bearer_challenge_stops_with_the_header_sentence
    oauth_teardown
    oauth_setup(challenge: :header)
    error = assert_raises(Rho::Error) { login! }
    assert_equal "unauthorized (401 without a Bearer challenge) — the server wants a header", error.message
  end

  def test_logout_unlinks_the_file_whole
    login!
    cli = self.cli
    Rho::Mcp::Oauth::Logout.call(cli, @row, @storage)
    assert_equal "logged out of fxo (its tokens and registration forgotten; the authorization server's own clock " \
                 "expires what it issued)\n", cli.out.string
    refute File.exist?(credential_path)
    assert_equal "no tokens", @storage.status.reason
  end
end
