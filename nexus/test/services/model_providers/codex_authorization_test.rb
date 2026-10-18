require "test_helper"

# The concrete Codex authorization adapter. This is not RFC 8628, so its
# endpoints and payload shapes are exercised directly.
class ModelProviders::CodexAuthorizationTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization
  REQUESTS = AUTH::Requests
  RESPONSES = AUTH::Responses

  # --- adapter facts ------------------------------------------------------

  test "the adapter exposes the expected endpoints" do
    assert_equal "https://auth.openai.com", AUTH::ISSUER
    assert_equal "app_EMoamEEZ73f0CkXaXp7hrann", AUTH::CLIENT_ID
    assert_equal "https://auth.openai.com/api/accounts/deviceauth/usercode", AUTH.user_code_url
    assert_equal "https://auth.openai.com/api/accounts/deviceauth/token", AUTH.device_token_url
    assert_equal "https://auth.openai.com/oauth/token", AUTH.token_url
    assert_equal "https://auth.openai.com/codex/device", AUTH.verification_url
    assert_equal "https://auth.openai.com/deviceauth/callback", AUTH.redirect_uri
  end

  test "the device-auth pair and the token endpoint sit under different prefixes" do
    # Deriving all four from one "api base" is the shape that ships a wrong
    # path: upstream builds `{issuer}/api/accounts` for device auth and posts
    # the token exchange to `{issuer}/oauth/token` directly.
    assert_includes AUTH.user_code_url, "/api/accounts/"
    assert_includes AUTH.device_token_url, "/api/accounts/"
    refute_includes AUTH.token_url, "/api/accounts"
    refute_includes AUTH.verification_url, "/api/accounts"
  end

  # --- requests ------------------------------------------------------------

  test "the user-code request posts only the client id as json" do
    prepared = REQUESTS.user_code_request

    assert_equal :post, prepared.http_method
    assert_equal AUTH.user_code_url, prepared.url
    assert_equal "application/json", prepared.headers.fetch("Content-Type")
    assert_equal({ "client_id" => AUTH::CLIENT_ID }, JSON.parse(prepared.body))
  end

  test "the poll request posts the device handle and user code as json" do
    prepared = REQUESTS.device_token_poll(device_auth_id: "dev-1", user_code: "BCDF-GHJK")

    assert_equal AUTH.device_token_url, prepared.url
    assert_equal "application/json", prepared.headers.fetch("Content-Type")
    assert_equal({ "device_auth_id" => "dev-1", "user_code" => "BCDF-GHJK" }, JSON.parse(prepared.body))
  end

  test "the code exchange is form encoded with the frozen redirect uri" do
    prepared = REQUESTS.code_exchange(authorization_code: "ac-1", code_verifier: "cv-1")

    assert_equal AUTH.token_url, prepared.url
    assert_equal "application/x-www-form-urlencoded", prepared.headers.fetch("Content-Type")
    assert_equal(
      { "grant_type" => "authorization_code", "code" => "ac-1",
        "redirect_uri" => AUTH.redirect_uri, "client_id" => AUTH::CLIENT_ID,
        "code_verifier" => "cv-1" },
      URI.decode_www_form(prepared.body).to_h
    )
  end

  test "the refresh posts exactly three json fields" do
    prepared = REQUESTS.token_refresh(refresh_token: "rt-1")

    assert_equal AUTH.token_url, prepared.url
    assert_equal "application/json", prepared.headers.fetch("Content-Type")
    assert_equal(
      { "client_id" => AUTH::CLIENT_ID, "grant_type" => "refresh_token", "refresh_token" => "rt-1" },
      JSON.parse(prepared.body)
    )
  end

  test "one endpoint carries two codecs, so the phase selects the encoding" do
    exchange = REQUESTS.code_exchange(authorization_code: "ac-1", code_verifier: "cv-1")
    refresh = REQUESTS.token_refresh(refresh_token: "rt-1")

    # The trap: same URL, different Content-Type. Choosing the codec from the
    # endpoint instead of the phase sends one of these in the other's encoding,
    # and the issuer answers with an error that looks like a bad credential.
    assert_equal exchange.url, refresh.url
    assert_equal "application/x-www-form-urlencoded", exchange.headers.fetch("Content-Type")
    assert_equal "application/json", refresh.headers.fetch("Content-Type")
  end

  test "the code-exchange body matches the upstream field order byte for byte" do
    prepared = REQUESTS.code_exchange(authorization_code: "ac 1", code_verifier: "cv/1")

    # Upstream builds this body by interpolation, so its field ORDER is part of
    # the shape we align to, and each value goes through percent-encoding.
    assert_equal(
      "grant_type=authorization_code&code=ac+1" \
      "&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback" \
      "&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=cv%2F1",
      prepared.body
    )
  end

  test "a blank secret is refused rather than posted as an empty field" do
    assert_raises(ArgumentError) { REQUESTS.device_token_poll(device_auth_id: " ", user_code: "u") }
    assert_raises(ArgumentError) { REQUESTS.device_token_poll(device_auth_id: "d", user_code: nil) }
    assert_raises(ArgumentError) { REQUESTS.code_exchange(authorization_code: "", code_verifier: "v") }
    assert_raises(ArgumentError) { REQUESTS.token_refresh(refresh_token: "") }
  end

  # --- the phase-specific status table -------------------------------------

  test "the same 404 is terminal for user code and pending for a poll" do
    # THE finding of this work package, pinned as one assertion so the two
    # halves can never drift apart: on the user-code endpoint 404 means the
    # server has device login disabled and the session must stop; on the poll
    # endpoint it means nobody has approved yet and the session must continue.
    user_code = RESPONSES.user_code(status: 404, body: "")
    poll = RESPONSES.device_token_poll(status: 404, body: "")

    assert_predicate user_code, :terminal?
    assert_equal :device_code_not_enabled, user_code.error
    assert_predicate poll, :pending?
  end

  test "a poll 403 is pending like its 404" do
    assert_predicate RESPONSES.device_token_poll(status: 403, body: ""), :pending?
  end

  test "no other poll status is pending" do
    [400, 401, 402, 405, 409, 429, 500, 502, 503].each do |status|
      outcome = RESPONSES.device_token_poll(status: status, body: "")

      assert_predicate outcome, :terminal?
      assert_equal :provider_error, outcome.error, "status #{status}"
    end
  end

  test "a user-code non-404 failure is a distinct terminal error" do
    outcome = RESPONSES.user_code(status: 500, body: "")

    assert_predicate outcome, :terminal?
    assert_equal :provider_error, outcome.error
  end

  # --- the poll interval ---------------------------------------------------

  test "the poll interval is accepted only as canonical decimal seconds in range" do
    # Upstream parses this from a STRING under a serde default, so an absent
    # field becomes 0 and polls without pause. Each rejection below is a shape
    # that would otherwise reach the scheduler.
    {
      "5" => 5, "1" => 1, "900" => 900,
    }.each do |raw, seconds|
      outcome = RESPONSES.user_code(status: 200, body: user_code_body(interval: raw))

      assert_predicate outcome, :ok?, raw.inspect
      assert_equal seconds, outcome.facts.fetch("interval_seconds")
    end

    ["0", "-1", "901", "05", " 5", "5 ", "5.0", "", "+5", "1e3", "abc"].each do |raw|
      outcome = RESPONSES.user_code(status: 200, body: user_code_body(interval: raw))

      assert_predicate outcome, :terminal?, raw.inspect
      assert_equal :unsupported_poll_interval, outcome.error, raw.inspect
    end
  end

  test "an integer interval is refused because the wire spells it as a string" do
    body = { "device_auth_id" => "d", "user_code" => "u", "interval" => 5 }.to_json
    outcome = RESPONSES.user_code(status: 200, body: body)

    assert_predicate outcome, :terminal?
    assert_equal :unsupported_poll_interval, outcome.error
  end

  test "a missing interval is refused rather than defaulted to zero" do
    body = { "device_auth_id" => "d", "user_code" => "u" }.to_json
    outcome = RESPONSES.user_code(status: 200, body: body)

    assert_predicate outcome, :terminal?
    assert_equal :unsupported_poll_interval, outcome.error
  end

  # --- success shapes ------------------------------------------------------

  test "the user code is read under either spelling upstream accepts" do
    aliased = { "device_auth_id" => "d-1", "usercode" => "BCDF", "interval" => "5" }.to_json
    outcome = RESPONSES.user_code(status: 200, body: aliased)

    assert_predicate outcome, :ok?
    assert_equal "BCDF", outcome.facts.fetch("user_code")
  end

  test "a poll 200 yields the single-use grant and nothing installable" do
    outcome = RESPONSES.device_token_poll(status: 200, body: grant_body)

    assert_predicate outcome, :ok?
    assert_equal %w[authorization_code code_challenge code_verifier], outcome.facts.keys
    # The verifier arrives FROM the issuer: this flow's PKCE material is
    # server-generated, so nothing here is ours to have produced.
    assert_equal "cv-1", outcome.facts.fetch("code_verifier")
  end

  test "an incomplete poll grant is terminal" do
    ModelProviders::CodexAuthorization::Responses::GRANT_FIELDS.each do |missing|
      body = JSON.parse(grant_body).except(missing).to_json
      outcome = RESPONSES.device_token_poll(status: 200, body: body)

      assert_predicate outcome, :terminal?, missing
      assert_equal :incomplete_response, outcome.error, missing
    end
  end

  test "a token response installs only when all three fields are present" do
    %i[code_exchange token_refresh].each do |phase|
      assert_predicate RESPONSES.public_send(phase, status: 200, body: token_body), :ok?

      ModelProviders::CodexAuthorization::Responses::TOKEN_FIELDS.each do |missing|
        body = JSON.parse(token_body).except(missing).to_json
        outcome = RESPONSES.public_send(phase, status: 200, body: body)

        # Upstream's decoder makes each field Optional. That is decoder
        # permissiveness, not a provider guarantee — and for a refresh the old
        # token is already spent, so a partial response must install nothing.
        assert_predicate outcome, :terminal?, "#{phase}/#{missing}"
        assert_equal :incomplete_response, outcome.error, "#{phase}/#{missing}"
      end
    end
  end

  # --- shapes observed on the live wire ------------------------------------
  #
  # Captured 2026-08-14 against https://auth.openai.com with the owner's
  # account, running the real four-phase device start. The issuer sends MORE
  # than upstream's structs declare in every phase; serde drops the extras
  # silently and so must we, or a field the issuer adds tomorrow becomes an
  # outage today. Values below are shapes, never captured secrets.

  test "the user-code response carries an expires_at that upstream and Nexus both ignore" do
    live = {
      "device_auth_id" => "d" * 43, "user_code" => "R20K-H1Q40", "interval" => "5",
      "expires_at" => "2026-08-14T08:46:49.000000Z",
    }.to_json
    outcome = RESPONSES.user_code(status: 200, body: live)

    assert_predicate outcome, :ok?
    # The window is DERIVED as poll_started_at + 900, exactly as upstream runs
    # its own 15-minute clock. An issuer-supplied expiry is not read, so the
    # two can never disagree about whose deadline governs.
    assert_equal %w[device_auth_id user_code interval_seconds], outcome.facts.keys
    assert_equal 5, outcome.facts.fetch("interval_seconds")
  end

  test "the poll grant response carries three extra fields that are dropped" do
    live = {
      "authorization_code" => "a" * 90, "code_challenge" => "c" * 43,
      "code_verifier" => "v" * 43, "status" => "approved",
      "user_code" => "R20K-H1Q40", "user_code_expiration" => "2026-08-14T08:46:49.000000Z",
    }.to_json
    outcome = RESPONSES.device_token_poll(status: 200, body: live)

    assert_predicate outcome, :ok?
    assert_equal %w[authorization_code code_challenge code_verifier], outcome.facts.keys
  end

  test "the token response carries four extra fields that are dropped" do
    live = {
      "access_token" => "a" * 1678, "token_type" => "Bearer", "expires_in" => 3600,
      "scope" => "openid profile email offline_access", "id_token" => "i" * 1830,
      "earliest_refresh_at" => 1_786_700_000, "refresh_token" => "r" * 196,
      "oai_is" => "o" * 1024,
    }.to_json
    outcome = RESPONSES.code_exchange(status: 200, body: live)

    assert_predicate outcome, :ok?
    # `expires_in` is CONSUMED rather than dropped — Nexus never guesses a
    # default TTL, so the credential's expiry has to come from the wire. The
    # other four (token_type, scope, earliest_refresh_at, oai_is) are still
    # dropped; `earliest_refresh_at` is a refresh-scheduling input a later
    # slice must decide on, not something to read by default.
    assert_equal %w[id_token access_token refresh_token expires_in_seconds], outcome.facts.keys
    assert_equal 3600, outcome.facts.fetch("expires_in_seconds")
  end

  test "the live pending status is 403 with a machine-readable code we do not read" do
    # Observed live. Upstream decides on STATUS alone and ignores the body, so
    # the code is recorded as evidence rather than consumed: reading it would
    # make us diverge the moment the issuer adds a second pending code.
    live = {
      "error" => {
        "message" => "Device authorization is pending. Please try again.",
        "type" => "invalid_request_error", "param" => nil,
        "code" => "deviceauth_authorization_pending",
      },
    }.to_json

    assert_predicate RESPONSES.device_token_poll(status: 403, body: live), :pending?
  end

  # --- bounds and malformed input ------------------------------------------

  test "an oversized body is refused before it is parsed" do
    oversized = { "device_auth_id" => "d", "user_code" => "u", "interval" => "5",
                  "padding" => "x" * Nexus::SizeBounds.fetch(:oauth_exchange_response_bound) }.to_json
    outcome = RESPONSES.user_code(status: 200, body: oversized)

    assert_predicate outcome, :terminal?
    # Not "malformed": we never read it. An operator chasing a parse bug in a
    # body nobody parsed is the diagnosis this separation prevents.
    assert_equal :oversized_response, outcome.error
  end

  test "an oversized field is its own finding, not a missing one" do
    huge = "x" * (Nexus::SizeBounds.fetch(:oauth_exchange_field_bound) + 1)
    body = { "device_auth_id" => huge, "user_code" => "u", "interval" => "5" }.to_json
    outcome = RESPONSES.user_code(status: 200, body: body)

    assert_predicate outcome, :terminal?
    assert_equal :oversized_field, outcome.error
  end

  test "malformed and non-object bodies are terminal for every phase" do
    ["", "not json", "[]", "null", '"text"', "12"].each do |body|
      %i[user_code device_token_poll code_exchange token_refresh].each do |phase|
        outcome = RESPONSES.public_send(phase, status: 200, body: body)

        assert_predicate outcome, :terminal?, "#{phase} #{body.inspect}"
        assert_equal :malformed_response, outcome.error, "#{phase} #{body.inspect}"
      end
    end
  end

  private

    def user_code_body(interval:)
      { "device_auth_id" => "d-1", "user_code" => "BCDF", "interval" => interval }.to_json
    end

    def grant_body
      { "authorization_code" => "ac-1", "code_challenge" => "cc-1", "code_verifier" => "cv-1" }.to_json
    end

    def token_body
      { "id_token" => "id-1", "access_token" => "at-1", "refresh_token" => "rt-1",
        "expires_in" => 3600 }.to_json
    end
end
