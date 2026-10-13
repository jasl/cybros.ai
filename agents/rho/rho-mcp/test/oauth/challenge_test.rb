require "test_helper"
require "faraday"
require "support/oauth_world"

# THE NO-TOKEN 401, CLASSIFIED FROM ITS HEADER ALONE: three headers, three sentences, no network; and the `:auto`
# double 401 against the real fixture — the legacy `initialize`'s error
# carries the challenge, the connection's `down:` is the classified
# sentence, and the daemon read no OAuth metadata and registered nothing.
class OauthChallengeTest < Minitest::Test
  include McpTest::OauthWorld

  def teardown = oauth_teardown

  def error_with(header)
    faraday = Faraday::UnauthorizedError.new("unauthorized", { status: 401, headers: header ? { "www-authenticate" => header } : {} })
    MCP::Client::RequestHandlerError.new("You are unauthorized", { method: "initialize" }, error_type: :unauthorized,
      original_error: faraday)
  end

  def test_a_bearer_challenge_naming_the_metadata_is_a_login
    challenge = Rho::Mcp::Oauth::Challenge.classify(error_with(
      'Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", scope="read write"'
    ))
    assert_predicate challenge, :oauth?
    assert_equal "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", challenge.resource_metadata
    assert_equal "read write", challenge.scope
    assert_equal "needs login — run `rho mcp login linear`", challenge.sentence("linear")
    assert_equal "needs login, and this host has no rho home to hold one — declare the server on a rho home",
      challenge.sentence("linear", home: false)
  end

  def test_a_bearer_challenge_without_the_metadata_names_both_doors
    ["Bearer", 'Bearer realm="fx"', 'Basic realm="x", Bearer error="invalid_token"'].each do |header|
      challenge = Rho::Mcp::Oauth::Challenge.classify(error_with(header))
      assert_predicate challenge, :bearer?, header
      assert_nil challenge.resource_metadata
      assert_equal "unauthorized (401 with a Bearer challenge naming no OAuth metadata) — a `headers` bearer, or " \
                   "`rho mcp login linear` if it speaks OAuth", challenge.sentence("linear")
    end
  end

  def test_no_bearer_challenge_wants_a_header
    ['Basic realm="fx"', nil, 'Digest realm="x", DPoP algs="ES256"'].each do |header|
      challenge = Rho::Mcp::Oauth::Challenge.classify(error_with(header))
      assert_predicate challenge, :header?, header.inspect
      assert_equal "unauthorized (401 without a Bearer challenge) — the server wants a header", challenge.sentence("linear")
    end
  end

  def test_unauthorized_is_the_gems_error_type_and_nothing_else
    assert Rho::Mcp::Oauth::Challenge.unauthorized?(error_with("Bearer"))
    forbidden = MCP::Client::RequestHandlerError.new("forbidden", { method: "x" }, error_type: :forbidden)
    refute Rho::Mcp::Oauth::Challenge.unauthorized?(forbidden)
    refute Rho::Mcp::Oauth::Challenge.unauthorized?(StandardError.new("x"))
  end

  # The real thing under `connect(mode: :auto)`: the probe's 401 is rescued
  # by the gem, the legacy handshake 401s again, and the second error is
  # classified; the row is `down:` with the verb named, the log line says
  # "no tokens", and the fixture counted no discovery read.
  def test_the_auto_handshakes_double_401_is_classified_and_reads_no_metadata
    oauth_setup
    connection = connection(storage: @storage)
    error = assert_raises(Rho::Mcp::Unavailable) { connection.open! }
    assert_equal "needs login — run `rho mcp login fxo`", error.message
    assert_predicate connection.challenge, :oauth?
    assert_equal "#{@base}/.well-known/oauth-protected-resource/mcp", connection.challenge.resource_metadata
    assert_equal "fx:read", connection.challenge.scope
    assert_includes @log, [:warn, "mcp.oauth.login_required", { server: "fxo", reason: "no tokens" }]
    assert_equal [0, 0, 0], issued.values_at("prm_reads", "metadata_reads", "registrations"), "the daemon read no OAuth document"
    refute File.exist?(credential_path), "nothing was written"
  end

  def test_on_a_homeless_host_the_sentence_names_the_missing_home
    oauth_setup
    connection = connection(storage: nil)
    error = assert_raises(Rho::Mcp::Unavailable) { connection.open! }
    assert_equal "needs login, and this host has no rho home to hold one — declare the server on a rho home", error.message
  end

  def test_the_other_two_flavours_reach_the_down_line
    oauth_setup(challenge: :bearer)
    error = assert_raises(Rho::Mcp::Unavailable) { connection.open! }
    assert_equal "unauthorized (401 with a Bearer challenge naming no OAuth metadata) — a `headers` bearer, or " \
                 "`rho mcp login fxo` if it speaks OAuth", error.message
    refute(@log.any? { |entry| entry[1] == "mcp.oauth.login_required" }, "both doors named, the verb not promised")
    oauth_teardown
    oauth_setup(challenge: :header)
    error = assert_raises(Rho::Mcp::Unavailable) { connection.open! }
    assert_equal "unauthorized (401 without a Bearer challenge) — the server wants a header", error.message
  end
end
