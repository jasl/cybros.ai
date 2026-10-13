require "test_helper"

# C2-OAuth: the whole authorization walked once, service to service.
#
# Every other suite tests one service against hand-built inputs. This one runs
# the real sequence — accept, claim, apply, claim, apply, claim, install, then
# a refresh over the result — so the SEAMS are exercised: each step consumes
# only what its predecessor actually produced. A service can be individually
# correct and still hand its successor the wrong thing, and nothing else here
# would notice.
#
# The response bodies are the shapes measured on the live wire 2026-08-14,
# including the fields the issuer sends that we drop.
class ModelProviders::CodexAuthorization::EndToEndTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization

  setup do
    @account = accounts(:cybros)
  end

  test "a device start walks from acceptance to an installed credential" do
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start"
    ).session

    assert_equal "user_code_request", session.semantic_exchange_kind
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "codex_subscription")
    refute_predicate policy, :enabled?

    # 1. user code
    step(session, 200, user_code_body) { |o| AUTH::Responses.user_code(**o) }

    assert_equal "awaiting_user", session.reload.progress
    assert_equal "device_token_poll", session.semantic_exchange_kind

    # 2. a pending poll, then 3. the grant
    step(session, 403, pending_body) { |o| AUTH::Responses.device_token_poll(**o) }

    assert_equal 1, session.reload.semantic_exchange_ordinal

    step(session, 200, grant_body) { |o| AUTH::Responses.device_token_poll(**o) }

    assert_equal "code_exchange", session.reload.semantic_exchange_kind
    assert_equal 0, ModelProviderCredential.count, "a grant is not a credential"
    refute_predicate policy.reload, :enabled?

    # 4. the exchange installs
    claim = AUTH::Claim.call(session: session.reload)
    result = AUTH::InstallCredential.call(
      session: session, task: claim.task, normalized_status: "http_200",
      outcome: AUTH::Responses.code_exchange(status: 200, body: token_body("first"))
    )

    assert_predicate result, :installed?
    assert_equal "completed", session.reload.state
    assert_predicate policy.reload, :enabled?
    credential = ModelProviderCredential.sole

    assert_equal "at-first", credential.secret
    assert_equal session.authorization_lineage_id, credential.authorization_lineage_id

    # Four claims, every one sealed, none still dispatching.
    tasks = session.oauth_tasks.order(:id)

    assert_equal %w[user_code_request device_token_poll device_token_poll code_exchange],
      tasks.map(&:exchange_kind)
    assert_empty tasks.select(&:dispatching?)
  end

  test "a refresh rotates the credential the device start installed" do
    credential = complete_device_start
    first_generation = credential.generation

    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "token_refresh"
    ).session
    claim = AUTH::Claim.call(session: session)

    # The seam that matters: the refresh spends the token the INSTALL wrote.
    assert_equal "rt-first", JSON.parse(claim.prepared.body).fetch("refresh_token")

    AUTH::InstallCredential.call(
      session: session, task: claim.task, normalized_status: "http_200",
      outcome: AUTH::Responses.token_refresh(status: 200, body: token_body("second"))
    )

    credential.reload

    assert_equal "at-second", credential.secret
    assert_equal "rt-second", credential.refresh_secret
    assert_operator credential.generation, :>, first_generation
    # A refresh continues a lineage rather than minting one.
    assert_equal session.authorization_lineage_id, credential.authorization_lineage_id
    assert_equal "completed", session.reload.state
  end

  test "a clear stops a live authorization and removes what was installed" do
    complete_device_start
    live = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start"
    ).session

    AUTH::ClearAuthorization.call(account: @account)

    assert_equal "revoked", live.reload.state
    assert_equal 0, ModelProviderCredential.count
    # And the revoked session can no longer claim anything.
    assert_equal :session_not_pending, AUTH::Claim.call(session: live).outcome
  end

  private

    def step(session, status, body)
      travel_to session.reload.next_action_at, with_usec: true if session.next_action_at > Time.current
      claim = AUTH::Claim.call(session: session.reload)

      assert_predicate claim, :claimed?, "claim refused: #{claim.outcome}"
      AUTH::ApplyDeviceStart.call(
        session: session, task: claim.task, normalized_status: "http_#{status}",
        outcome: yield({ status: status, body: body })
      )
    end

    def complete_device_start
      session = AUTH::AcceptSession.call(
        account: @account, issuing_user: users(:owner), kind: "device_start"
      ).session
      step(session, 200, user_code_body) { |o| AUTH::Responses.user_code(**o) }
      step(session, 200, grant_body) { |o| AUTH::Responses.device_token_poll(**o) }
      claim = AUTH::Claim.call(session: session.reload)
      AUTH::InstallCredential.call(
        session: session, task: claim.task, normalized_status: "http_200",
        outcome: AUTH::Responses.code_exchange(status: 200, body: token_body("first"))
      )
      ModelProviderCredential.sole
    end

    def user_code_body
      { "device_auth_id" => "d" * 43, "user_code" => "RAWE-NUA2L", "interval" => "5",
        "expires_at" => "2026-08-14T11:24:30.000000Z" }.to_json
    end

    def pending_body
      { "error" => { "message" => "Device authorization is pending. Please try again.",
                     "type" => "invalid_request_error", "param" => nil,
                     "code" => "deviceauth_authorization_pending" } }.to_json
    end

    def grant_body
      { "authorization_code" => "a" * 90, "code_challenge" => "c" * 43,
        "code_verifier" => "v" * 43, "status" => "approved", "user_code" => "RAWE-NUA2L",
        "user_code_expiration" => "2026-08-14T11:24:30.000000Z" }.to_json
    end

    def token_body(label)
      { "id_token" => "header.#{Base64.urlsafe_encode64(
        { "https://api.openai.com/auth" => { "chatgpt_account_id" => "acct_1" } }.to_json,
        padding: false
      )}.sig",
        "access_token" => "at-#{label}", "refresh_token" => "rt-#{label}",
        "token_type" => "Bearer", "expires_in" => 864_000, "scope" => "openid profile email",
        "earliest_refresh_at" => 1_787_483_370, "oai_is" => "o" * 64 }.to_json
    end
end
