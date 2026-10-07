require "test_helper"

# THE CODEX LANE'S HEADERS (alignment audit F3, F5; codex-rs pin
# 883af106): the credential's `ChatGPT-Account-ID`, the session/thread pair
# keyed on the prompt cache key and the per-request id — every one a
# CONSUMER fact the gem's Config headers carry, merged only at execution.
# The assembled client is where they are spelled, once, for both hosts.
class ModelCatalog::AssembleClientTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  # bearer_auth_provider.rs inserts the header only for `Some(account_id)`:
  # an identity the token never carried sends nothing, and the lane still
  # runs on its Bearer — never fail closed on a label.
  test "the codex lane sends ChatGPT-Account-ID exactly when the credential carries the identity" do
    profile = DevModelLane.profile_for("codex_subscription/gpt-6.1-sol")

    identified = client(profile, credential: codex_credential(identity: "acct_123"))
    assert_equal "acct_123", identified.config.headers.fetch("ChatGPT-Account-ID")
    assert_equal "Bearer access-token", identified.config.headers.fetch("Authorization")

    anonymous = client(profile, credential: codex_credential(identity: nil))
    refute anonymous.config.headers.key?("ChatGPT-Account-ID")
    assert_equal "Bearer access-token", anonymous.config.headers.fetch("Authorization")
  end

  # codex-api/src/endpoint/responses.rs: `x-client-request-id` is the
  # request's own id, `session-id` and `thread-id` the cache affinity key
  # ("ChatGPT derives cache affinity from the Responses session-id header",
  # client.rs) — the same key `prompt_cache_key` carries in the body.
  test "the codex lane keys its session on the invocation's cache key and its request on the invocation" do
    profile = DevModelLane.profile_for("codex_subscription/gpt-6.1-sol")
    conversation = Conversation.create!(
      workspace: workspaces(:shared), creating_user: @creator, answering_user: users(:agent)
    )
    hosted = ModelInvocation.create!(
      conversation: conversation, creating_user: @creator,
      internal_creation_key: "conversation_reply:#{SecureRandom.uuid_v7}",
      **DevModelLane.invocation_attributes(DevModelLane.selection(workload: "text_generation", account: @account))
    )

    headers = client(profile, credential: codex_credential(identity: "acct_123"), invocation: hosted).config.headers
    assert_equal conversation.public_id, headers.fetch("session-id")
    assert_equal conversation.public_id, headers.fetch("thread-id")
    assert_equal hosted.public_id, headers.fetch("x-client-request-id")

    # A one-off has no session to key on: the request id alone rides.
    inference_request = DevModelLane.create_invocation!(inference_request: InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: @creator, workload: "text_generation"
    ))
    unkeyed = client(profile, credential: codex_credential(identity: nil), invocation: inference_request).config.headers
    refute unkeyed.key?("session-id")
    refute unkeyed.key?("thread-id")
    assert_equal inference_request.public_id, unkeyed.fetch("x-client-request-id")
  end

  # The compile client (no credential, before the claim) and every other
  # lane carry none of them: these are codex's backend headers, not a
  # kernel convention.
  test "a non-codex lane and the credentialless compile carry none of the codex headers" do
    codex = DevModelLane.profile_for("codex_subscription/gpt-6.1-sol")
    compile = client(codex, credential: nil, invocation: nil).config.headers
    assert_empty compile.keys & %w[ChatGPT-Account-ID session-id thread-id x-client-request-id]
    refute compile.key?("Authorization")

    inference_request = DevModelLane.create_invocation!(inference_request: InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: @creator, workload: "text_generation"
    ))
    api_key = ModelProviderCredential.new(
      account: @account, provider_id: "openai_api", material_kind: "api_key", secret: "sk-test",
      provider_account_identity: "acct_123"
    )
    plain = client(DevModelLane.profile_for("openai_api/gpt-6.1-sol"), credential: api_key, invocation: inference_request)
      .config.headers
    assert_equal "Bearer sk-test", plain.fetch("Authorization")
    assert_empty plain.keys & %w[ChatGPT-Account-ID session-id thread-id x-client-request-id]
  end

  private

    def client(profile, credential:, invocation: nil)
      ModelCatalog::AssembleClient.call(
        profile: profile, base_url: "https://chatgpt.com/backend-api/codex",
        credential: credential, host: "solid_queue", streaming: true, invocation: invocation
      )
    end

    # The row the device flow installs, unsaved: the assembler reads it by
    # reference and never writes.
    def codex_credential(identity:)
      ModelProviderCredential.new(
        account: @account, provider_id: ModelProviders::CodexAuthorization::PROVIDER_ID,
        material_kind: "oauth_tokens", secret: "access-token", refresh_secret: "refresh-token",
        authorization_lineage_id: SecureRandom.uuid_v7, expires_at: 1.hour.from_now,
        provider_account_identity: identity
      )
    end
end
