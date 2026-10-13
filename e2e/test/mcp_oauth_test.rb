require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "shellwords"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"
require "support/mcp_fixture/declarations"
require "support/mcp_fixture/host"
require "support/mcp_fixture/login_verb"

# MCP OAUTH ON RHO: an OAuth-protected streamable-HTTP server is connected by the official gem's own
# authorization-code + PKCE flow, driven ONCE by a person through `rho mcp login SERVER` — a browser
# (here `$BROWSER`, the harness's stub that follows the one redirect), a loopback callback in the
# CLI process — its tokens kept ONE PRIVATE FILE PER SERVER under rho's home and sent by the
# daemon's transport as the `Authorization` header: refreshed by the gem on a 401, never printed,
# never logged, and refused (never re-registered, never browsed) by a daemon that has no person to
# ask. The server is the fixture server behind rho-mcp's own mock authorization server + resource
# server (`server.rb oauth PORT`, the unit suite's app under puma), with a token the journey expires
# through the fixture's door so a refresh, a renewal failure and a refusal are all observed inside
# one journey — a property, never a clock. Every login is a bounded child of its own group whose
# stdin is never the harness's terminal (`E2E::McpFixture::LoginVerb`). Driven through the shipped
# binary: `rho mcp`, `rho mcp login` (with the stub, and with `--no-browser` + the pasted redirect),
# `rho mcp logout`, `rho mcp probe`, `rho do`, `rho runner`, and restarts of the same home.
#
# THE STEPS, in order on one home: DOWN AT BOOT (nothing registered, no
# OAuth metadata read, no registration, no browser); THE LOGIN (the
# consent line, the S256 request with the resource and both loopback
# redirect forms, the 0600 file under 0700, the counters); ANNOUNCED
# WITHOUT RESTARTING; THE BEARER ON THE WIRE and nowhere else (the negative
# over every log, every verb's output); A RESTART KEEPS THE LOGIN; THE SILENT REFRESH (a rotated
# pair, no notice, the old token gone from every surface); THE TRANSIENT
# RENEWAL FAILURE is unreachable, never a login, and the next call
# reconnects; THE REFUSAL (tokens cleared → the model-facing sentence, the
# registration kept, the second call refused from the file with no
# network); A RE-LOGIN REFRESHES THE LIVE DAEMON, no boot;
# STEP-UP (the union sentence, `pending_scope`, the login sending the
# union); `--no-browser` AND THE PASTE; NO DAEMON (`rho mcp` from the
# file, the probe on the read-only view, the logout); THE NEGATIVES (the
# two config faults; a credential file rho refuses to read is its own
# sentence naming chmod, never the verb); OPTIONAL AUTHORIZATION (the
# fixture's door: an anonymous `/mcp` answered while the PRM stays
# published — the verb logs in all the same and the daemon's row sends
# the token on every call) AND THE ISS COMPARED FIRST (a denial from the
# wrong issuer is the mismatch alone on the shipped binary).
#
# ONE CEREMONY PER FILE, ONE GRANT: the full-mode daemon on its own home;
# every restart re-boots the SAME home. The fixture is booted BEFORE the
# daemon and closed by the journey. No paid lane: a REAL public server is
# `live_mcp_oauth`'s, once, by hand.
class McpOauthTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  AWAIT_SECONDS = 120
  LOOP_POLL = 1
  SERVER = "fxo".freeze
  FIXTURE = E2E::McpFixture::Host::FIXTURE
  BROWSER_STUB = File.expand_path("../support/mcp_fixture/browser.rb", __dir__)
  # The `$BROWSER` of the stub-driven logins: rho's launcher splits it as
  # a shell would (`Rho::Cli::Browser`), so it is joined as one.
  BROWSER = Shellwords.join([Gem.ruby, BROWSER_STUB]).freeze
  REFRESH_LINE = "daemon refreshed fxo: 7 tools announced".freeze
  NEXT_BOOT_LINE = "no daemon running; fxo's tools will be announced at the next boot".freeze
  LOGOUT_LINE = "logged out of fxo (its tokens and registration forgotten; the authorization server's own clock " \
                "expires what it issued)".freeze
  LOGIN_SENTENCE = "mcp server fxo: authentication required — its authorization was rejected and this process cannot " \
                   "log in; ask the person to run `rho mcp login fxo`; every call to mcp__fxo__* fails until then".freeze
  STEP_UP_SENTENCE = "mcp server fxo: authentication required — it now requires scope fx:write (granted: fx:read) and " \
                     "this process cannot log in; ask the person to run `rho mcp login fxo` (which asks for fx:read " \
                     "fx:write); every call to mcp__fxo__* fails until then".freeze
  CHMOD_SENTENCE = "mcp server fxo: credential file mcp/credentials/fxo.json must be private (mode 0600), got 0644 — " \
                   "ask the person to chmod it; every call to mcp__fxo__* fails until then".freeze
  CREDENTIAL_DOWN = "credential file mcp/credentials/fxo.json must be private (mode 0600), got 0644 — rho refuses to " \
                    "read it".freeze
  OPTIONAL_CLAUSE = " — authorization is optional here: the server answered anonymously too, and every call carries " \
                    "the token from now on".freeze
  STDIO_FAULT = 'mcp server "fxs": oauth is an http server\'s; a stdio server reads its credentials from `env`'.freeze
  HEADER_FAULT = 'mcp server "fxh": either a bearer header or oauth, not both'.freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-mcp-oauth-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    @fixture_port = E2E::McpFixture::Host.free_port
    @fixture_log_path = File.join(@home, "fixture.log")
    @secrets = []
    @verb_outputs = []
    write_settings
    @actor.visit("/")
    assert @page.has_text?("Dashboard")
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      warn_log(@fixture_log_path, "oauth fixture")
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
    end
  rescue StandardError => error
    warn "Could not capture the mcp_oauth E2E logs: #{error.class}: #{error.message}"
  ensure
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    stop_fixture
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_an_oauth_server_is_logged_in_to_once_refreshed_refused_recovered_and_never_leaks_a_token
    project = connect!
    down_at_boot_nothing_registered_nothing_read
    the_login
    announced_by_the_live_daemon
    the_bearer_on_the_wire_and_nowhere_else(project)
    a_restart_keeps_the_login(project)
    the_silent_refresh(project)
    the_transient_renewal_failure_is_not_a_login(project)
    the_refusal(project)
    a_relogin_refreshes_the_live_daemon(project)
    step_up(project)
    no_browser_and_the_paste
    no_daemon
    the_negatives(project)
    optional_authorization_and_the_iss_compared_first(project)
  end

  private

    # ---- 1. DOWN AT BOOT, NOTHING REGISTERED, NOTHING READ ----

    def down_at_boot_nothing_registered_nothing_read
      runner = rho("runner")
      refute_match(/^FAILED:/, runner, "an extension failed to load:\n#{runner}")
      refute_match(/mcp__fxo__/, runner, "a row down at boot announces nothing:\n#{runner}")
      listed = rho("mcp")
      assert_match(/^server:\s+fxo\s+http\s+#{Regexp.escape(fixture_url)}\s+serves agent\s+down: needs login — run `rho mcp login fxo`$/,
        listed, "rho mcp did not list fxo down for want of a login:\n#{listed}")
      assert_match(/^  auth:    oauth — needs login \(no tokens\)$/, listed, listed)
      assert_match(/event=mcp\.oauth\.login_required server=fxo reason="no tokens"/, @daemon.log_text,
        "the boot never logged the login it needs:\n#{oauth_log_lines}")
      counts = issued
      assert_equal [0, 0, 0, 0], counts.values_at("prm_reads", "metadata_reads", "registrations", "authorizations"),
        "the daemon read OAuth metadata, registered or browsed for a row nobody logged in to: #{counts.inspect}"
    end

    # ---- 2. THE LOGIN ----

    def the_login
      output = login!
      lines = output.lines.map(&:chomp)
      assert_equal "authorizing with #{as_issuer} for scopes fx:read (resource #{fixture_url})", lines.fetch(0),
        "the challenge's fx:read won over PRM's fx:read fx:write:\n#{output}"
      assert_match(%r{\Aopen this URL to authorize rho: #{Regexp.escape(as_issuer)}/authorize\?}, lines.fetch(1), output)
      assert_equal "logged in to fxo (issuer #{as_issuer}; scope fx:read; 7 tools listed; refresh token held)", lines.fetch(2), output
      assert_equal REFRESH_LINE, lines.fetch(3), output
      assert_equal 4, lines.length, "the verb printed more than its four lines:\n#{output}"

      authorize = URI.decode_www_form(URI(lines.fetch(1).split(": ", 2).last).query).to_h
      assert_equal "S256", authorize.fetch("code_challenge_method")
      assert_equal fixture_url, authorize.fetch("resource")
      assert_match(%r{\Ahttp://127\.0\.0\.1:\d+/callback\z}, authorize.fetch("redirect_uri"))
      refute_empty authorize.fetch("state")
      record = issued
      assert_equal ["http://127.0.0.1/callback", authorize.fetch("redirect_uri")], record.dig("registration", "redirect_uris"),
        "the registration carried both loopback redirect forms, and the AS honoured them: #{record["registration"].inspect}"
      assert_equal "native", record.dig("registration", "application_type"), "the spec's application_type for a loopback client"
      assert_equal [1, 1, true], record.values_at("registrations", "authorizations", "token_resource_seen"), record.inspect

      written = store
      assert_equal "0600", mode(credential_path), "the credential file is private"
      assert_equal "0700", mode(File.dirname(credential_path)), "the credentials directory is private"
      assert_equal fixture_url, written.fetch("url")
      assert_equal as_issuer, written.dig("client_information", "issuer")
      assert_match(/\Art-/, written.dig("tokens", "refresh_token").to_s, "a refresh token is held")
      refute_nil written["issued_at"], "the ONE stamp is written at the login"
      remember_secrets!
    end

    # ---- 3. ANNOUNCED WITHOUT RESTARTING ----

    def announced_by_the_live_daemon
      assert_match(/event=mcp\.announced server=fxo tools=7 bytes=\d+/, @daemon.log_text, "the daemon never announced fxo")
      listed = rho("mcp")
      assert_match(/^server:\s+fxo\s+http\s+#{Regexp.escape(fixture_url)}\s+serves agent\s+connected\s+\S+\s+fx-server 1\.0\.0$/,
        listed, "rho mcp did not print a connected fxo:\n#{listed}")
      assert_match(logged_in_line, listed, listed)
      runner = rho("runner")
      assert_match(/^extension: rho\.mcp \(#{(fxo_names + ["skill"]).map { |n| Regexp.escape(n) }.join(", ")}\)$/, runner,
        "the seven names announced beside the plane's skill:\n#{runner}")
    end

    # ---- 4. THE BEARER ON THE WIRE, AND NOWHERE ELSE ----

    def the_bearer_on_the_wire_and_nowhere_else(project)
      row, output = echo!(project, "over oauth")
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_equal "agent_application", row.dig("addressed_to", "role"), "addressed to the agent: #{row.inspect}"
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}over oauth", output.strip
      remember_secrets!
      assert_equal "Bearer #{store.dig("tokens", "access_token")}", issued.fetch("authorization_headers").last,
        "the header on the wire is the stored access token"
      assert_token_free!
    end

    def a_restart_keeps_the_login(project)
      marks = issued.values_at("registrations", "authorizations")
      @daemon.stop
      restart!
      announced_by_the_live_daemon
      row, output = echo!(project, "after restart")
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}after restart", output.strip
      assert_equal marks, issued.values_at("registrations", "authorizations"), "the restart needed no new login"
      assert_token_free!
    end

    # ---- 5. THE SILENT REFRESH ----

    def the_silent_refresh(project)
      before = store
      refreshes = issued.fetch("refreshes")
      refreshed = log_count(/event=mcp\.oauth\.refreshed server=fxo\b/)
      login_required = log_count(/event=mcp\.oauth\.login_required server=fxo\b/)
      expire!
      row, output = echo!(project, "after the ttl")
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}after the ttl", output.strip, "no notice line: the refresh is transparent"
      after = store
      refute_equal before.dig("tokens", "access_token"), after.dig("tokens", "access_token"), "the access token rotated"
      refute_equal before.dig("tokens", "refresh_token"), after.dig("tokens", "refresh_token"), "the refresh token rotated"
      refute_equal before.fetch("issued_at"), after.fetch("issued_at"), "the stamp moved"
      assert_equal refreshes + 1, issued.fetch("refreshes"), "one refresh for one expiry"
      assert_equal({ "grant_type" => "refresh_token", "resource" => fixture_url }, issued.fetch("token_requests").last,
        "the refresh carried the resource (RFC 8707)")
      assert_equal refreshed + 1, log_count(/event=mcp\.oauth\.refreshed server=fxo\b/), oauth_log_lines
      assert_equal login_required, log_count(/event=mcp\.oauth\.login_required server=fxo\b/), "never a login:\n#{oauth_log_lines}"
      remember_secrets!
      # The rotated PREVIOUS token is in the set: the live redaction
      # remembers what it saw.
      assert_token_free!
    end

    # ---- 6. THE TRANSIENT RENEWAL FAILURE IS NOT A LOGIN ----

    def the_transient_renewal_failure_is_not_a_login(project)
      refreshes = issued.fetch("refreshes")
      login_required = log_count(/event=mcp\.oauth\.login_required server=fxo\b/)
      switch!("token_outage", "on")
      expire!
      row, output = echo!(project, "under the outage")
      assert_equal "failed", row.fetch("status"), "a renewal failure is outcome: failed: #{row.inspect}"
      # A failed call's content is the runner's frame around the sentence
      # (`The tool could not run: <class>: <sentence>.`); the sentence is
      # what the model reads.
      assert_match(/mcp server fxo stopped answering during mcp__fxo__echo: could not renew its authorization \(.+\); the next call reconnects/,
        output, "the renewal sentence, never a login:\n#{output}")
      refute_match(/rho mcp login/, output, "no verb is named for a blip:\n#{output}")
      assert_match(/event=mcp\.oauth\.renewal_failed server=fxo tool=mcp__fxo__echo\b/, @daemon.log_text, oauth_log_lines)
      assert_equal login_required, log_count(/event=mcp\.oauth\.login_required server=fxo\b/), oauth_log_lines
      assert_match(/\Art-/, store.dig("tokens", "refresh_token").to_s, "the refresh token is intact")
      listed = rho("mcp")
      assert_match(/^server:\s+fxo\s+http\s+.*down: unreachable \(could not renew its authorization \(.+\)\) at \d\d:\d\d:\d\d$/,
        listed, listed)
      assert_match(logged_in_line, listed, "still logged in:\n#{listed}")

      switch!("token_outage", "off")
      row, output = echo!(project, "back")
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_match(/\Anote: mcp server fxo had stopped answering \(.+\) and was reconnected for this call; any state it held is gone\n#{Regexp.escape(E2E::McpFixture::ECHO_TEXT_PREFIX)}back\z/,
        output.strip)
      assert_equal refreshes + 1, issued.fetch("refreshes"), "the reconnect refreshed once"
      remember_secrets!
    end

    # ---- 7. THE REFUSAL ----

    def the_refusal(project)
      switch!("revoke", "on")
      row, output = echo!(project, "revoked")
      assert_equal "failed", row.fetch("status"), row.inspect
      assert_includes output, LOGIN_SENTENCE
      assert_match(/event=mcp\.oauth\.login_required server=fxo tool=mcp__fxo__echo reason="tokens cleared \(the refresh was rejected\)"/,
        @daemon.log_text, oauth_log_lines)
      listed = rho("mcp")
      assert_match(/^server:\s+fxo\s+http\s+.*down: needs login — run `rho mcp login fxo`$/, listed, listed)
      assert_match(/^  auth:    oauth — needs login \(no tokens\)$/, listed, listed)
      written = store
      refute written.key?("tokens"), "the gem's invalid_grant arm cleared them: #{written.keys.inspect}"
      assert_equal "dcr-1", written.dig("client_information", "client_id"), "the registration is kept"
      assert_equal 1, issued.fetch("registrations")

      prm_reads = issued.fetch("prm_reads")
      row, output = echo!(project, "still revoked")
      assert_equal "failed", row.fetch("status"), row.inspect
      assert_includes output, LOGIN_SENTENCE
      assert_equal prm_reads, issued.fetch("prm_reads"), "the file-first revive reads no network"
    end

    # ---- 8. A RE-LOGIN REFRESHES THE LIVE DAEMON, NO BOOT ----

    def a_relogin_refreshes_the_live_daemon(project)
      switch!("revoke", "off")
      output = login!
      assert_includes output, "logged in to fxo (issuer #{as_issuer}; scope fx:read; 7 tools listed; refresh token held)\n"
      assert_includes output, "#{REFRESH_LINE}\n"
      record = issued
      assert_equal [1, 2], record.values_at("registrations", "authorizations"), "the stored registration reused: #{record.inspect}"
      remember_secrets!
      row, output = echo!(project, "after the login")
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}after the login", output.strip
      assert_match(/^server:\s+fxo\s+http\s+.*serves agent\s+connected\s/, rho("mcp"))
    end

    # ---- 9. STEP-UP ----

    def step_up(project)
      switch!("require_scope", "fx:write")
      row, output = echo!(project, "narrow")
      assert_equal "failed", row.fetch("status"), row.inspect
      assert_includes output, STEP_UP_SENTENCE
      written = store
      assert_equal "fx:read fx:write", written.fetch("pending_scope")
      assert_match(/\Aat-/, written.dig("tokens", "access_token").to_s, "the tokens are valid and kept")
      listed = rho("mcp")
      assert_match(/^  auth:    oauth — needs login \(the server now requires scope fx:write; the login asks for fx:read fx:write\)$/,
        listed, listed)
      prm_reads = issued.fetch("prm_reads")
      row, output = echo!(project, "still narrow")
      assert_equal "failed", row.fetch("status"), row.inspect
      assert_includes output, STEP_UP_SENTENCE
      assert_equal prm_reads, issued.fetch("prm_reads"), "a standing pending_scope is refused from the file"

      output = login!
      assert_equal "authorizing with #{as_issuer} for scopes fx:read fx:write (resource #{fixture_url})", output.lines.first.chomp,
        "the recorded union is the one scope sent:\n#{output}"
      assert_includes output, "#{REFRESH_LINE}\n"
      assert_equal "fx:read fx:write", issued.dig("authorize", "scope")
      written = store
      refute written.key?("pending_scope"), "the verb cleared it"
      assert_equal "fx:read fx:write", written.dig("tokens", "scope")
      remember_secrets!
      row, output = echo!(project, "wide")
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}wide", output.strip
      switch!("require_scope", "")
    end

    # ---- 10. `--no-browser` AND THE PASTE ----

    def no_browser_and_the_paste
      assert_equal "#{LOGOUT_LINE}\n", rho("mcp", "logout", "fxo")
      refute_path_exists credential_path, "the file is gone whole"
      assert_match(/^  auth:    oauth — needs login \(no tokens\)$/, rho("mcp"))

      output, code = paste_login!
      @secrets << code
      assert_includes output, "logged in to fxo (issuer #{as_issuer}; scope fx:read; 7 tools listed; refresh token held)\n"
      assert_includes output, "#{REFRESH_LINE}\n"
      remember_secrets!
    end

    # ---- 11. NO DAEMON ----

    def no_daemon
      @daemon.stop
      # The probe FIRST: the token it presents is the one the paste minted
      # a moment ago, and the read-only view renews nothing.
      refreshes = issued.fetch("refreshes")
      probed = rho("mcp", "probe", "fxo")
      assert_match(/^server:\s+fxo\s+http\s+#{Regexp.escape(fixture_url)}\s+serves agent\s+connected\s+\S+\s+fx-server 1\.0\.0$/,
        probed, "the probe did not connect on the read-only view:\n#{probed}")
      assert_match(/^  tools:   7 listed — 7 would be announced, [\d,]+ bytes$/, probed, probed)
      fxo_names.each { |name| assert_match(/^    #{Regexp.escape(name)}  [\d,]+ bytes/, probed, probed) }
      assert_equal refreshes, issued.fetch("refreshes"), "the read-only view spent no refresh"
      @verb_outputs << probed

      listed = rho("mcp")
      lines = listed.lines.map(&:chomp)
      assert_equal "no daemon running — `rho mcp probe NAME` connects from here", lines.fetch(0), listed
      # Inherited disabled rows can precede this fixture's server. Its own
      # launch and immediately following credential status remain exact.
      fxo = lines.index { |line| line.start_with?("server:    fxo  ") }
      refute_nil fxo, listed
      assert_equal "server:    fxo  http  #{fixture_url}  serves agent  not connected from this process", lines.fetch(fxo), listed
      assert_match(logged_in_line, lines.fetch(fxo + 1), "the auth line from the file alone:\n#{listed}")
      assert_token_free!

      assert_equal "#{LOGOUT_LINE}\n", rho("mcp", "logout", "fxo")
      listed = rho("mcp")
      assert_match(/^  auth:    oauth — needs login \(no tokens\)$/, listed, listed)
      marks = issued.values_at("registrations", "prm_reads")
      probed = rho("mcp", "probe", "fxo")
      assert_match(/^server:\s+fxo\s+http\s+#{Regexp.escape(fixture_url)}\s+down: needs login — run `rho mcp login fxo`$/,
        probed, probed)
      assert_equal marks, issued.values_at("registrations", "prm_reads"), "a no-token probe registers nothing and reads no PRM"
    end

    # ---- 12. THE NEGATIVES ----

    def the_negatives(project)
      assert_includes login!, "#{NEXT_BOOT_LINE}\n"
      remember_secrets!
      write_settings(faulty_rows: true)
      restart!
      listed = rho("mcp")
      assert_match(/^server:\s+fxs\s+stdio\s+.*down: config: #{Regexp.escape(STDIO_FAULT)}$/, listed, listed)
      assert_match(/^server:\s+fxh\s+http\s+.*down: config: #{Regexp.escape(HEADER_FAULT)}$/, listed, listed)
      assert_match(/^server:\s+fxo\s+http\s+.*serves agent\s+connected\s/, listed, "one row's fault is one row's:\n#{listed}")

      File.chmod(0o644, credential_path)
      login_required = log_count(/event=mcp\.oauth\.login_required server=fxo\b/)
      row, output = echo!(project, "wide open")
      assert_equal "failed", row.fetch("status"), row.inspect
      assert_includes output, CHMOD_SENTENCE
      assert_match(/event=mcp\.oauth\.credential_file server=fxo reason="credential file mcp\/credentials\/fxo\.json must be private \(mode 0600\), got 0644"/,
        @daemon.log_text, oauth_log_lines)
      assert_equal login_required, log_count(/event=mcp\.oauth\.login_required server=fxo\b/), "never spelled needs login:\n#{oauth_log_lines}"
      listed = rho("mcp")
      assert_match(/^server:\s+fxo\s+http\s+.*down: #{Regexp.escape(CREDENTIAL_DOWN)}$/, listed, listed)
      assert_match(/^  auth:    oauth — credential file mcp\/credentials\/fxo\.json must be private \(mode 0600\), got 0644$/, listed, listed)

      File.chmod(0o600, credential_path)
      row, output = echo!(project, "fixed")
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_match(/\Anote: mcp server fxo had refused its credential file \(.+\) and was reconnected for this call; any state it held is gone\n#{Regexp.escape(E2E::McpFixture::ECHO_TEXT_PREFIX)}fixed\z/,
        output.strip)
      assert_token_free!
    end

    # ---- 13. OPTIONAL AUTHORIZATION, AND THE ISS COMPARED FIRST ----

    # The fixture's door (`optional`): `/mcp` answers an untokened POST through the transport while
    # the PRM and an untokened GET's 405 still publish the AS. No 401 classifies anything, so the
    # verb reads what the server publishes and logs in through the same flow; the row — logged out
    # and in again under the running daemon — sends the token on every call: the fixture's
    # `anonymous` counter stands still under the probe and the echo, and the new token is on the
    # wire. Then exercise the issuer mismatch on the shipped binary: a denial from the wrong issuer
    # (`deny` + `tamper_iss`) is the `iss` mismatch alone on stderr, exit 1, and the impostor's
    # `access_denied` text is quoted nowhere.
    def optional_authorization_and_the_iss_compared_first(project)
      switch!("optional", "on")
      assert_equal "#{LOGOUT_LINE}\n", rho("mcp", "logout", "fxo")
      output = login!
      lines = output.lines.map(&:chomp)
      assert_equal "authorizing with #{as_issuer} for scopes fx:read (resource #{fixture_url})", lines.fetch(0),
        "the GET's challenge scope rode into the consent line:\n#{output}"
      assert_match(%r{\Aopen this URL to authorize rho: #{Regexp.escape(as_issuer)}/authorize\?}, lines.fetch(1), output)
      assert_equal "logged in to fxo (issuer #{as_issuer}; scope fx:read; 7 tools listed; refresh token held)#{OPTIONAL_CLAUSE}",
        lines.fetch(2), output
      assert_equal REFRESH_LINE, lines.fetch(3), output
      assert_equal 4, lines.length, "the verb printed more than its four lines:\n#{output}"
      remember_secrets!
      listed = rho("mcp")
      assert_match(/^  auth:    oauth — logged in \(tokens issued \d{4}-\d\d-\d\d \d\d:\d\d:\d\d; issuer #{Regexp.escape(as_issuer)}; scope fx:read; refresh token held; optional: the server answers anonymously too\)$/,
        listed, "the row does not say the authorization is optional:\n#{listed}")
      @verb_outputs << listed

      anonymous = issued.fetch("anonymous")
      probed = rho("mcp", "probe", "fxo")
      assert_match(/^server:\s+fxo\s+http\s+#{Regexp.escape(fixture_url)}\s+serves agent\s+connected\s/, probed,
        "the probe did not connect on the read-only view:\n#{probed}")
      @verb_outputs << probed
      row, _output = echo!(project, "with the token")
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_equal anonymous, issued.fetch("anonymous"), "a logged-in row let a call through untokened: #{issued.inspect}"
      assert_includes issued.fetch("authorization_headers"), "Bearer #{store.dig("tokens", "access_token")}",
        "the token the door made optional rode on the wire all the same"
      assert_token_free!

      switch!("deny", "on")
      switch!("tamper_iss", "on")
      result = E2E::McpFixture::LoginVerb.run(["mcp", "login", SERVER], env: { "BROWSER" => BROWSER }, home: @home,
        nexus_url: @base_url)
      @verb_outputs << result.output << result.errors
      refute result.timed_out, "the login from the wrong issuer hung:\n#{result.output}\n#{result.errors}"
      refute_predicate result.status, :success?, "a denial from the wrong issuer logged in:\n#{result.output}"
      assert_includes result.errors, "fxo's authorization response named issuer `#{fixture_base}/other`, not the " \
                                     "authorization server rho sent you to (`#{as_issuer}`) — RFC 9207 `iss` mismatch; " \
                                     "nothing was exchanged", "the iss mismatch was not the sentence:\n#{result.errors}"
      refute_includes result.output + result.errors, "access_denied", "the impostor's error text was quoted"
      refute_includes result.output + result.errors, "the person said no", "the impostor's description was quoted"
      switch!("tamper_iss", "off")
      switch!("deny", "off")
      switch!("optional", "off")
    end

    # ---- the settings ----

    # The OAuth row: http (the agent address), every tool, no `oauth`
    # sub-object — a 401 with an OAuth challenge is what makes it one. The
    # faulty rows: `oauth` on a stdio row, `oauth` beside a
    # lower-case `authorization` header on a loopback http row.
    def write_settings(faulty_rows: false)
      rows = { SERVER => { "transport" => "http", "url" => fixture_url, "tools" => ["*"] } }
      if faulty_rows
        rows["fxs"] = { "transport" => "stdio", "command" => Gem.ruby, "args" => [FIXTURE], "tools" => ["*"], "oauth" => {} }
        rows["fxh"] = { "transport" => "http", "url" => fixture_url, "tools" => ["*"],
                        "headers" => { "authorization" => "Bearer fixture-static-0123" }, "oauth" => {} }
      end
      File.write(File.join(@home, "settings.json"),
        JSON.pretty_generate(E2E::RhoDaemon.dev_settings(plugins: { "rho.mcp" => { "enabled" => true, "configuration" => { "servers" => rows } } })), perm: 0o600)
    end

    def fixture_base = "http://127.0.0.1:#{@fixture_port}"

    def fixture_url = "#{fixture_base}/mcp"

    def as_issuer = "#{fixture_base}/oauth"

    def fxo_names = E2E::McpFixture::TOOLS.map { |tool| "mcp__#{SERVER}__#{tool.fetch("name")}" }

    def logged_in_line
      /^  auth:    oauth — logged in \(tokens issued \d{4}-\d\d-\d\d \d\d:\d\d:\d\d; issuer #{Regexp.escape(as_issuer)}; scope fx:read(?: fx:write)?; refresh token held\)$/
    end

    # ---- the store ----

    def credential_path = File.join(@home, "mcp", "credentials", "#{SERVER}.json")

    def store = JSON.parse(File.read(credential_path, encoding: Encoding::UTF_8))

    def mode(path) = format("%04o", File.stat(path).mode & 0o777)

    # ---- the fixture ----

    def issued = JSON.parse(Net::HTTP.get(URI("#{fixture_base}/fixture/issued")))

    def switch!(name, value)
      response = Net::HTTP.post(URI("#{fixture_base}/fixture/#{name}"), value)
      assert_equal "200", response.code, "the fixture switch #{name} refused: #{response.body}"
    end

    # THE DOOR: every live access token expired at once, so the refresh
    # the next call spends is a property of that call, never a race
    # against the fixture's clock.
    def expire! = switch!("expire", "")

    # Every token the fixture ever minted, registered for the diagnostic
    # hygiene AND kept for the journey's own negative.
    def remember_secrets!
      issued.fetch("tokens").each do |value|
        next if @secrets.include?(value)

        @secrets << E2E::SecretHygiene.register(value)
      end
    end

    # THE NEGATIVE: no access token, refresh token or authorization code on any surface a person, a
    # model or a log reads — the daemon's stdout, rho's structured log, every verb's captured
    # output, and `rho mcp` / `rho mcp probe` read now.
    def assert_token_free!
      refute_empty @secrets, "nothing to search for"
      surfaces = {
        "daemon.log" => File.read(@daemon.log_path, encoding: Encoding::UTF_8).scrub,
        "rho.log" => @daemon.log_text,
        "the verbs' output" => @verb_outputs.join("\n"),
        "rho mcp" => rho("mcp"),
      }
      surfaces["rho mcp probe fxo"] = rho("mcp", "probe", "fxo") if File.file?(credential_path)
      surfaces.each do |name, text|
        @secrets.each do |secret|
          refute_includes text, secret, "#{name} carries a token or code (#{secret[0, 6]}…)"
        end
      end
    end

    # The fixture under puma (`E2E::McpFixture::Host`), booted BEFORE the
    # daemon that lists it and ready once the port answers.
    def start_fixture
      @fixture_pid = E2E::McpFixture::Host.spawn(entry: "oauth", port: @fixture_port, log: @fixture_log_path)
      E2E::McpFixture::Host.await_ready!(@fixture_port, log: @fixture_log_path)
    rescue E2E::McpFixture::Host::NotListening => error
      flunk "the oauth fixture never listened: #{error.message}"
    end

    def stop_fixture
      E2E::McpFixture::Host.stop(@fixture_pid) if @fixture_pid
      @fixture_pid = nil
    end

    # ---- the CLI ----

    def rho(*args)
      output, status = @daemon.cli(*args)
      assert_predicate status, :success?, "rho #{args.first} failed:\n#{output}"
      output
    end

    # `rho mcp login fxo` with the harness's `$BROWSER`: the stub follows
    # the authorization URL's one redirect to the verb's loopback callback.
    def login! = login_verb(env: { "BROWSER" => BROWSER })

    # `rho mcp login fxo --no-browser` with `$BROWSER` unset and stdin
    # piped: the journey reads the printed URL, performs the GET itself,
    # and writes the redirect's `Location` back — what a person on a
    # headless box does. Answers the output and the authorization code
    # the redirect carried.
    def paste_login!
      code = nil
      output = login_verb("--no-browser", env: { "BROWSER" => nil }) do |session|
        url = session.url
        location = Net::HTTP.get_response(URI(url))["location"] if url
        code = URI.decode_www_form(URI(location).query).to_h["code"] if location
        session.paste(location)
      end
      refute_nil code, "the authorization server did not redirect with a code:\n#{output}"
      [output, code]
    end

    # THE LOGIN VERB as a bounded child of its own group
    # (`E2E::McpFixture::LoginVerb`): stdin never the terminal, stdout the
    # lines pinned, stdout and stderr both kept for the negative (the
    # interpreter's own warnings land on stderr beside a refusal's
    # sentence); a verb that has not exited inside LoginVerb::SECONDS is
    # terminated and flunks with what it printed.
    def login_verb(*flags, env:, &block)
      result = E2E::McpFixture::LoginVerb.run(["mcp", "login", SERVER, *flags], env: env, home: @home,
        nexus_url: @base_url, &block)
      @verb_outputs << result.output << result.errors
      return result.output if result.status&.success?

      flunk "rho mcp login #{flags.join(" ")} #{result.timed_out ? "hung past #{E2E::McpFixture::LoginVerb::SECONDS} s" : "failed"}:" \
            "\n#{result.output}\n#{result.errors}"
    end

    # ONE ECHO THROUGH THE MODEL: the mock's directive for `mcp__fxo__echo`;
    # answers the task row and its output as the model would read it.
    def echo!(project, text)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("echo", "text" => text)} -- done", project)
      done = await_run_status(loop, "completed")
      row = done.fetch("tasks").find { |task| task["tool_name"] == "mcp__fxo__echo" }
      refute_nil row, summarize(done)
      [row, task_output(loop, row.fetch("key"))]
    end

    # `rho do`: the conversation, its turn, and the loop backing it.
    def open_turn(prompt, project, *flags)
      output = rho("do", prompt, "--model", MODEL, "--dir", project, *flags)
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    # THE DIRECTIVE, as the mock parses it: `name:<url-encoded json>`.
    def directive(raw_name, arguments)
      "mcp__#{SERVER}__#{raw_name}:#{CGI.escape(JSON.generate(arguments))}"
    end

    # ---- the world ----

    def connect!
      start_fixture
      agent_announcements = agent_announcement_count
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      @workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")
      E2E.enable_dev_lane!
      E2E.hosts.start
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      @daemon.control(:post, "/environment", body: { root: project })
      await_rho_ready
      await_agent_announced(after: agent_announcements)
      project
    end

    # The same home, booted again: the credentials stand, no new grant. A
    # stale announcement would answer the readiness wait for a daemon that
    # is gone, so it is cleared before the boot.
    def restart!
      FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
      agent_announcements = agent_announcement_count
      @daemon.start
      await_workspace_state("adopted")
      await_rho_ready
      await_agent_announced(after: agent_announcements)
    end

    def await_rho_ready
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
    end

    AGENT_ANNOUNCED = /event=executor\.announced tools=\d+ address=agent\b/

    def agent_announcement_count = @daemon.log_text.scan(AGENT_ANNOUNCED).length

    def await_agent_announced(after:)
      @daemon.await("the agent address never announced its tools") { agent_announcement_count > after ? true : nil }
    end

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    def log_count(pattern) = @daemon.log_text.scan(pattern).length

    def oauth_log_lines = @daemon.log_text.scan(/event=mcp\.\S+.*/).join("\n")

    # ---- the reads ----

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_detail(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").fetch("task")

    def task_output(loop, task_key) = task_detail(loop, task_key)["output"].to_s

    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def await_run_status(loop, status)
      await("the loop #{loop} never reached #{status}") do
        row = loop_row(loop)
        flunk "the loop failed: #{row["failure_reason"].inspect} #{summarize(row)}" if row["status"] == "failed" && status != "failed"
        row if row["status"] == status
      end
    end

    def await(message, every: LOOP_POLL)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}#{task["tool_name"] ? "/#{task["tool_name"]}" : ""}" \
          "#{task["error"] ? "/#{task["error"]["key"]}" : ""})"
      end.join(" ")
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
