require "test_helper"
require "support/oauth_world"
require "stringio"

# ONE PROVIDER CLASS, TWO INTERACTIONS.
# Headless: the gem's flow against the real fixture reaches the validator
# after discovery and stops there — the refusal recorded as data, nothing
# registered, nothing browsed; the step-up mark alone writes a
# `pending_scope`. Interactive: the consent line before any registration
# (the issuer it names kept for the verb's `iss` comparison), the URL
# printed FIRST then handed to the injected browser — a launcher that did
# not start (false, or none on this host) said in one line, the wait kept
# — the callback handler waiting on the listener and on stdin. The client
# metadata is the references' set with both loopback redirect forms.
class OauthProviderTest < Minitest::Test
  include McpTest::OauthWorld

  def setup = oauth_setup
  def teardown = oauth_teardown

  def test_the_client_metadata_is_the_references_set_with_both_redirect_forms
    metadata = Rho::Mcp::Oauth::Provider.client_metadata("http://127.0.0.1:4711/callback")
    assert_equal({ "client_name" => "rho", "grant_types" => %w[authorization_code refresh_token], "response_types" => %w[code],
                   "token_endpoint_auth_method" => "none",
                   "redirect_uris" => %w[http://127.0.0.1/callback http://127.0.0.1:4711/callback] }, metadata)
    refute metadata.key?("client_uri")
    refute(metadata.keys.any? { |key| key.start_with?("software_") })
    assert_predicate metadata, :frozen?
  end

  def test_the_headless_provider_refuses_after_discovery_and_before_any_registration
    provider = Rho::Mcp::Oauth::Provider.headless(row: @row, storage: @storage)
    assert_kind_of MCP::Client::OAuth::Provider, provider
    assert_nil provider.refusal
    error = assert_raises(MCP::Client::OAuth::Flow::AuthorizationRefusedError) do
      MCP::Client::OAuth::Flow.new(provider: provider).run!(server_url: "#{@base}/mcp",
        resource_metadata_url: "#{@base}/.well-known/oauth-protected-resource/mcp", scope: "fx:read")
    end
    assert_match(/refused by `authorization_request_validator`/, error.message)
    refusal = provider.refusal
    assert_equal "#{@base}/oauth", refusal.authorization_server
    assert_equal ["fx:read"], refusal.scopes
    assert_equal "#{@base}/mcp", refusal.resource
    assert_equal [1, 1, 0, 0], issued.values_at("prm_reads", "metadata_reads", "registrations", "authorizations"),
      "discovery read, nothing registered, nothing browsed"
    assert_nil @storage.pending_scope, "no step-up mark, no pending scope"
    assert_nil @storage.client_information
  end

  def test_the_headless_handlers_raise_the_gems_own_refusal_as_a_belt
    provider = Rho::Mcp::Oauth::Provider.headless(row: @row, storage: @storage)
    error = assert_raises(MCP::Client::OAuth::Flow::AuthorizationRefusedError) { provider.redirect_handler.call("http://x") }
    assert_equal "mcp server fxo needs a login this process cannot perform; run `rho mcp login fxo`", error.message
    assert_raises(MCP::Client::OAuth::Flow::AuthorizationRefusedError) { provider.callback_handler.call }
  end

  # The transport's mark around the gem's step-up entry is what tells the
  # validator to write the union; the same refusal without it writes none.
  def test_under_the_step_up_mark_the_refusal_records_the_pending_scope
    provider = Rho::Mcp::Oauth::Provider.headless(row: @row, storage: @storage)
    request = MCP::Client::OAuth::AuthorizationRequest.new(authorization_server: "#{@base}/oauth", scopes: %w[fx:read fx:write],
      server_url: "#{@base}/mcp", resource: "#{@base}/mcp")
    refute provider.stepping_up?
    provider.step_up do
      assert_predicate provider, :stepping_up?
      assert_equal false, provider.refuse!(request)
    end
    refute provider.stepping_up?
    assert_equal "fx:read fx:write", @storage.pending_scope
    assert_equal request, provider.refusal
  end

  def test_the_interactive_provider_prints_the_consent_the_url_and_launches_the_browser
    out = StringIO.new
    opened = []
    listener = Rho::Mcp::Oauth::Callback.new(seconds: 5).bind
    provider = Rho::Mcp::Oauth::Provider.interactive(row: @row, storage: @storage, callback: listener, out: out,
      browser: ->(url) { opened << url })
    assert_equal listener.redirect_uri, provider.redirect_uri
    assert_includes provider.client_metadata.fetch("redirect_uris"), listener.redirect_uri
    request = MCP::Client::OAuth::AuthorizationRequest.new(authorization_server: "#{@base}/oauth", scopes: ["fx:read"],
      server_url: "#{@base}/mcp", resource: "#{@base}/mcp")
    assert_nil provider.issuer
    assert_equal true, provider.authorization_request_validator.call(request)
    assert_equal "authorizing with #{@base}/oauth for scopes fx:read (resource #{@base}/mcp)\n", out.string
    assert_equal "#{@base}/oauth", provider.issuer, "the issuer rho sent the person to, kept for the iss comparison"
    provider.redirect_handler.call(URI("#{@base}/oauth/authorize?state=s"))
    assert_equal "open this URL to authorize rho: #{@base}/oauth/authorize?state=s\n", out.string.lines.last
    assert_equal ["#{@base}/oauth/authorize?state=s"], opened
    Net::HTTP.get_response(URI("#{listener.redirect_uri}?code=c&state=s"))
    assert_equal ["c", "s", nil], provider.callback_handler.call
  ensure
    listener&.close
  end

  # The launcher answers whether it started; false (a missing opener, a
  # failed spawn) or no launcher at all is ONE line after the URL, flushed,
  # and the callback handler still waits on the loopback.
  def test_a_launcher_that_did_not_start_is_said_once_after_the_url_and_the_wait_goes_on
    [->(_url) { false }, nil].each do |launcher|
      out = StringIO.new
      listener = Rho::Mcp::Oauth::Callback.new(seconds: 5).bind
      provider = Rho::Mcp::Oauth::Provider.interactive(row: @row, storage: @storage, callback: listener, out: out,
        browser: launcher)
      provider.redirect_handler.call("http://as/authorize")
      assert_equal "open this URL to authorize rho: http://as/authorize\n" \
                   "the browser did not open — open the URL above by hand; rho keeps waiting for the redirect to its " \
                   "loopback callback\n", out.string, launcher.inspect
      Net::HTTP.get_response(URI("#{listener.redirect_uri}?code=c&state=s"))
      assert_equal ["c", "s", nil], provider.callback_handler.call
    ensure
      listener&.close
    end
  end

  def test_under_no_browser_the_url_is_printed_not_launched_and_stdin_is_read_too
    out = StringIO.new
    opened = []
    listener = Rho::Mcp::Oauth::Callback.new(seconds: 5).bind
    paste = StringIO.new("http://127.0.0.1:1/callback?code=pasted&state=s\n")
    provider = Rho::Mcp::Oauth::Provider.interactive(row: @row, storage: @storage, callback: listener, out: out,
      browser: ->(url) { opened << url }, no_browser: true, input: paste)
    provider.redirect_handler.call("http://as/authorize")
    assert_equal "open this URL to authorize rho: http://as/authorize\n", out.string
    assert_empty opened
    assert_equal ["pasted", "s", nil], provider.callback_handler.call
  ensure
    listener&.close
  end

  # THE URL LEAVES THE PROCESS BEFORE THE WAIT: a person who must copy it
  # (or a harness that reads it off a pipe) sees it at once — a piped
  # `$stdout` is block-buffered, and a URL held in the buffer for the
  # five-minute wait is a login nobody can perform.
  def test_the_printed_lines_are_flushed_before_the_wait_on_a_piped_out
    reader, writer = IO.pipe
    writer.sync = false
    listener = Rho::Mcp::Oauth::Callback.new(seconds: 5).bind
    provider = Rho::Mcp::Oauth::Provider.interactive(row: @row, storage: @storage, callback: listener, out: writer,
      browser: ->(_url) { nil }, no_browser: true, input: StringIO.new)
    request = MCP::Client::OAuth::AuthorizationRequest.new(authorization_server: "#{@base}/oauth", scopes: ["fx:read"],
      server_url: "#{@base}/mcp", resource: "#{@base}/mcp")
    provider.authorization_request_validator.call(request)
    provider.redirect_handler.call("http://as/authorize")
    assert_equal "authorizing with #{@base}/oauth for scopes fx:read (resource #{@base}/mcp)\n" \
                 "open this URL to authorize rho: http://as/authorize\n",
      reader.read_nonblock(4096), "the lines sat in the buffer"
  ensure
    listener&.close
    writer&.close
    reader&.close
  end
end
