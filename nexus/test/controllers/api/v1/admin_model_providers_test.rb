require "test_helper"

class API::V1::AdminModelProvidersTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:owner)
    @account = accounts(:cybros)
    @token = create_access_token_fixture(user: @human, name: "Operator", plane: :platform)
  end

  def auth = { "Authorization" => "Bearer #{@token.secret}" }

  def lanes
    get "/api/v1/admin/model_providers", headers: auth
    assert_response :success
    response.parsed_body.fetch("model_providers")
  end

  def lane(provider_id) = lanes.find { |row| row.fetch("id") == provider_id }

  test "every provider this server serves is listed with both facts that gate it" do
    rows = lanes

    assert_equal ModelCatalog.current.providers.keys.sort, rows.map { |row| row.fetch("id") }
    dev = lane("dev")
    # Independent, and a surface collapsing them would leave somebody who
    # installed a key wondering why nothing ran.
    assert_includes dev.keys, "enabled"
    assert_includes dev.keys, "configured"
    assert_operator dev.fetch("models"), :>, 0
  end

  # A credentialless lane is honestly configured: there is no secret to
  # install, so a console must not offer a key field for it.
  test "a lane that needs no credential says it is configured" do
    assert_equal "none", lane("dev").fetch("credentials")
    assert lane("dev").fetch("configured")
  end

  # THE PROVIDER'S OWN CLOCK (the provider admission floor, 2026-09-15):
  # always present, null until a lane's provider named a `Retry-After`,
  # the ISO time it named while that time stands, null again once it has
  # passed — read against the admitter's clock, never the process's.
  test "every lane carries unavailable_until, null when no floor stands" do
    rows = lanes

    rows.each { |row| assert_includes row.keys, "unavailable_until" }
    assert_nil lane("dev").fetch("unavailable_until")
  end

  test "a floored lane says until when, and a passed floor says nothing" do
    ModelProviderRuntimeState.raise_floor(
      account_id: @account.id, provider_id: "dev", until_at: DatabaseClock.now + 60
    )

    until_at = lane("dev").fetch("unavailable_until")
    assert_kind_of String, until_at
    assert_in_delta (Time.current + 60).to_f, Time.iso8601(until_at).to_f, 5.0
    assert_nil lane("openrouter").fetch("unavailable_until"), "the floor is the lane's, not the account's"

    ModelProviderRuntimeState.where(account: @account, provider_id: "dev").update_all(
      next_admission_at: DatabaseClock.now - 1
    )
    assert_nil lane("dev").fetch("unavailable_until"), "cleared by the clock, no writer"
  end

  test "the singular lane answer carries the floor too" do
    ModelProviderRuntimeState.raise_floor(
      account_id: @account.id, provider_id: "openrouter", until_at: DatabaseClock.now + 60
    )

    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: true, expected_lock_version: nil } }, as: :json, headers: auth
    assert_response :success

    assert_kind_of String, response.parsed_body.dig("model_provider", "unavailable_until")
  end

  # The presenter takes the caller's clock: no default, so a render cannot
  # silently compare the admitter's floor to some other process's time.
  test "the presenter has no clock of its own" do
    assert_raises(ArgumentError) do
      AgentAPI::ModelProviderPresenter.row(
        provider_id: "dev", provider: ModelCatalog.current.providers.fetch("dev"),
        policy: nil, credential: nil, runtime_state: nil, models: 1
      )
    end
  end

  test "enabling a lane creates its row and answers with the version to send next" do
    assert_nil lane("openrouter").fetch("lock_version")

    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: true, expected_lock_version: nil } }, as: :json, headers: auth
    assert_response :success

    row = response.parsed_body.fetch("model_provider")
    assert row.fetch("enabled")
    refute_nil row.fetch("lock_version"), "a client that cannot read it cannot call the command again"

    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: false, expected_lock_version: row.fetch("lock_version") } },
      as: :json, headers: auth
    assert_response :success
    refute response.parsed_body.dig("model_provider", "enabled")
  end

  # Two people looking at one account's settings is the ordinary case, so
  # a stale version is a conflict rather than a last-writer-wins overwrite.
  test "a stale lock version is refused rather than applied" do
    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: true, expected_lock_version: 99 } }, as: :json, headers: auth

    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  test "a provider this server does not serve is a 404, not a lane made on faith" do
    put "/api/v1/admin/model_providers/nope/lane",
      params: { command: { enabled: true, expected_lock_version: nil } }, as: :json, headers: auth

    assert_response :not_found
  end

  # THE KEY IS WRITE-ONLY. Not a preview, not a length, not a fingerprint:
  # what a caller may learn is that one is installed.
  test "installing a key says a key is installed and never says the key" do
    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-secret-value" } }, as: :json, headers: auth
    assert_response :success

    row = response.parsed_body.fetch("model_provider")
    assert row.fetch("configured")
    assert row.fetch("enabled")
    assert_equal "api_key", row.fetch("material_kind")
    refute_includes response.body, "sk-secret-value"
    refute_includes response.body, "secret"
  end

  test "rotation is the same verb, and a repeat cannot invalidate a working key" do
    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-one" } }, as: :json, headers: auth
    credential = ModelProviderCredential.find_by(account: @account, provider_id: "openrouter")
    first = credential.generation
    policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "openrouter")
    ModelProviders::DisableLane.call(account: @account, provider_id: "openrouter", expected_lock_version: policy.lock_version)

    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-one" } }, as: :json, headers: auth
    assert_response :success
    assert_equal first, credential.reload.generation, "the same material is a no-op"
    assert response.parsed_body.dig("model_provider", "enabled")
    assert_predicate policy.reload, :enabled?

    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-two" } }, as: :json, headers: auth
    assert_response :success
    assert_equal first + 1, credential.reload.generation
  end

  test "a blank key is refused rather than stored" do
    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "   " } }, as: :json, headers: auth

    # `parameter_invalid` is one of the family codes, and the family
    # promises its status: a caller may branch on the code alone.
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    assert_nil ModelProviderCredential.find_by(account: @account, provider_id: "openrouter")
    assert_nil ModelProviderPolicy.find_by(account: @account, provider_id: "openrouter")
  end

  test "removing a key leaves the lane and says it is no longer configured" do
    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-one" } }, as: :json, headers: auth

    delete "/api/v1/admin/model_providers/openrouter/api_key", headers: auth
    assert_response :success
    refute response.parsed_body.dig("model_provider", "configured")

    delete "/api/v1/admin/model_providers/openrouter/api_key", headers: auth
    assert_response :not_found
  end

  # THE REFUSAL'S WORD IS THE SERVICE'S (audit wire-3): a lane holding an
  # OAuth pair authenticates some other way, and both api-key verbs answer
  # `409 material_kind_conflict` — the code `models.json` lists and the
  # docs name, never a bare HTTP status name.
  test "an api key on a lane that authenticates some other way is 409 material_kind_conflict" do
    ModelProviderCredential.create!(
      account: @account, provider_id: "codex_subscription", material_kind: "oauth_tokens",
      secret: "access", refresh_secret: "refresh", authorization_lineage_id: SecureRandom.uuid_v7,
      expires_at: 4.hours.from_now
    )

    put "/api/v1/admin/model_providers/codex_subscription/api_key",
      params: { command: { api_key: "sk-one" } }, as: :json, headers: auth
    assert_response :conflict
    assert_equal "material_kind_conflict", response.parsed_body.dig("error", "code")

    delete "/api/v1/admin/model_providers/codex_subscription/api_key", headers: auth
    assert_response :conflict
    assert_equal "material_kind_conflict", response.parsed_body.dig("error", "code")
    assert_equal "oauth_tokens", ModelProviderCredential.find_by!(account: @account, provider_id: "codex_subscription").material_kind,
      "the pair is untouched"
  end

  test "installing a key enables the provider and makes its models available" do
    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-one" } }, as: :json, headers: auth

    get "/api/v1/admin/models?available=true", headers: auth
    refs = response.parsed_body.fetch("models").map { |model| model.fetch("provider") }
    assert_includes refs, "openrouter",
      "the two commands together are what turn a listing from empty into useful"
  end

  test "unauthenticated management requests are refused" do
    get "/api/v1/admin/model_providers"
    assert_response :unauthorized

    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-one" } }, as: :json
    assert_response :unauthorized
  end

  test "a lane command against an unavailable catalog is 503 model_plane_unavailable" do
    ModelCatalog.stub(:current, -> { raise ModelCatalog::Unavailable }) do
      put "/api/v1/admin/model_providers/openrouter/lane",
        params: { command: { enabled: true, expected_lock_version: nil } }, as: :json, headers: auth
    end
    assert_response :service_unavailable
    assert_equal "model_plane_unavailable", response.parsed_body.dig("error", "code")
  end

  test "an API Session completes the operator workflow and member discovery sees its result" do
    post "/api/v1/session", params: { email: identities(:owner).email, password: "password" }, as: :json
    assert_response :created
    session_auth = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }

    get "/api/v1/admin/model_providers/openrouter", headers: session_auth
    assert_response :success
    row = response.parsed_body.fetch("model_provider")
    refute row.fetch("enabled")
    refute row.fetch("configured")

    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: true, expected_lock_version: row.fetch("lock_version") } },
      as: :json, headers: session_auth
    assert_response :success
    version = response.parsed_body.dig("model_provider", "lock_version")

    get "/api/v1/admin/models?workload=text_generation", headers: session_auth
    assert_response :success
    rows = response.parsed_body.fetch("models")
    assert rows.all? { |model| model.fetch("workload") == "text_generation" }
    model = rows.find { |entry| entry.fetch("provider") == "openrouter" }
    assert_equal "missing_credential", model.fetch("unavailable_reason")

    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-operator-workflow" } }, as: :json, headers: session_auth
    assert_response :success
    refute_includes response.body, "sk-operator-workflow"

    get "/api/v1/admin/models?workload=text_generation&available=true", headers: session_auth
    assert_response :success
    models = response.parsed_body.fetch("models")
    assert_includes models.map { |entry| entry.fetch("provider") }, "openrouter"

    member_secret = connect_agent_session(steward: users(:owner), agent_identifier: "operator-discovery").access_secret
    get "/agent_api/v1/models?workload=text_generation&available=true",
      headers: { "Authorization" => "Bearer #{member_secret}" }
    assert_response :success
    assert_equal models, response.parsed_body.fetch("models")

    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: false, expected_lock_version: version } },
      as: :json, headers: session_auth
    assert_response :success
    refute response.parsed_body.dig("model_provider", "enabled")
    assert response.parsed_body.dig("model_provider", "configured")

    delete "/api/v1/admin/model_providers/openrouter/api_key", headers: session_auth
    assert_response :success
    refute response.parsed_body.dig("model_provider", "configured")
    assert ModelProviderPolicy.exists?(account: @account, provider_id: "openrouter")
  end

  test "only a live Human administrator can read or change provider state" do
    post "/api/v1/session", params: { email: identities(:member).email, password: "password" }, as: :json
    assert_response :created
    member_session = response.parsed_body.fetch("token")
    get "/api/v1/admin/model_providers", headers: { "Authorization" => "Bearer #{member_session}" }
    assert_response :forbidden
    assert_equal "administrator_required", response.parsed_body.dig("error", "code")

    tokens = [
      create_access_token_fixture(user: users(:owner), name: "Human member plane").secret,
      connect_agent_session(steward: users(:owner), agent_identifier: "denied-operator").access_secret,
      create_bound_credential(executor: task_executors(:address), name: "Executor").secret,
    ]
    tokens.each do |secret|
      denied_auth = { "Authorization" => "Bearer #{secret}" }
      get "/api/v1/admin/models", headers: denied_auth
      assert_response :unauthorized
      put "/api/v1/admin/model_providers/openrouter/api_key",
        params: { command: { api_key: "sk-denied" } }, as: :json, headers: denied_auth
      assert_response :unauthorized
    end
    assert_nil ModelProviderCredential.find_by(account: @account, provider_id: "openrouter")
  end

  test "a demoted operator loses management immediately on both platform credential forms" do
    users(:member).change_role(to: :admin)
    token = create_access_token_fixture(user: users(:member), name: "Admin", plane: :platform)
    post "/api/v1/session", params: { email: identities(:member).email, password: "password" }, as: :json
    assert_response :created
    session_secret = response.parsed_body.fetch("token")
    users(:member).reload.change_role(to: :member)

    get "/api/v1/admin/model_providers", headers: { "Authorization" => "Bearer #{token.secret}" }
    assert_response :unauthorized
    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: true, expected_lock_version: nil } }, as: :json,
      headers: { "Authorization" => "Bearer #{session_secret}" }
    assert_response :forbidden
    assert_equal "administrator_required", response.parsed_body.dig("error", "code")
    assert_nil ModelProviderPolicy.find_by(account: @account, provider_id: "openrouter")
  end

  test "a browser cookie permits inspection but cannot mutate or rescue a wrong-plane bearer" do
    sign_in_as users(:owner)
    get "/api/v1/admin/model_providers/openrouter"
    assert_response :success

    put "/api/v1/admin/model_providers/openrouter/api_key",
      params: { command: { api_key: "sk-cookie" } }, as: :json
    assert_response :unauthorized

    member = create_access_token_fixture(user: users(:owner), name: "Member")
    get "/api/v1/admin/models", headers: { "Authorization" => "Bearer #{member.secret}" }
    assert_response :unauthorized
    assert_nil ModelProviderCredential.find_by(account: @account, provider_id: "openrouter")
  end

  test "non-api-key lanes refuse installation even before any credential exists" do
    %w[codex_subscription dev].each do |provider_id|
      put "/api/v1/admin/model_providers/#{provider_id}/api_key",
        params: { command: { api_key: "sk-wrong-kind" } }, as: :json, headers: auth
      assert_response :conflict
      assert_equal "material_kind_conflict", response.parsed_body.dig("error", "code")
      assert_nil ModelProviderCredential.find_by(account: @account, provider_id: provider_id)
    end
  end

  test "malformed lane fields cannot be coerced into a successful mutation" do
    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: true, expected_lock_version: nil } }, as: :json, headers: auth
    assert_response :success
    policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "openrouter")

    ["not-an-integer", -1, 0.5, 2_147_483_648].each do |version|
      put "/api/v1/admin/model_providers/openrouter/lane",
        params: { command: { enabled: false, expected_lock_version: version } }, as: :json, headers: auth
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
      assert policy.reload.enabled?
    end
    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: "false", expected_lock_version: policy.lock_version } }, as: :json, headers: auth
    assert_response :bad_request
    assert policy.reload.enabled?
  end

  test "a stale reader cannot overwrite another operator's disable" do
    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: true, expected_lock_version: nil } }, as: :json, headers: auth
    assert_response :success
    version = response.parsed_body.dig("model_provider", "lock_version")
    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: false, expected_lock_version: version } }, as: :json, headers: auth
    assert_response :success
    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: true, expected_lock_version: version } }, as: :json, headers: auth
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
    refute ModelProviderPolicy.find_by!(account: @account, provider_id: "openrouter").enabled?
  end

  test "unknown provider and absent lane are refused without creating state" do
    get "/api/v1/admin/model_providers/nope", headers: auth
    assert_response :not_found
    put "/api/v1/admin/model_providers/nope/api_key",
      params: { command: { api_key: "sk-nope" } }, as: :json, headers: auth
    assert_response :not_found
    put "/api/v1/admin/model_providers/openrouter/lane",
      params: { command: { enabled: false, expected_lock_version: nil } }, as: :json, headers: auth
    assert_response :not_found
    assert_nil ModelProviderPolicy.find_by(account: @account, provider_id: "openrouter")
    assert_nil ModelProviderCredential.find_by(account: @account, provider_id: "nope")
  end

  test "management reads report an unavailable catalog instead of an empty inventory" do
    ModelCatalog.stub(:current, -> { raise ModelCatalog::Unavailable }) do
      %w[models model_providers model_providers/openrouter].each do |resource|
        get "/api/v1/admin/#{resource}", headers: auth
        assert_response :service_unavailable
        assert_equal "model_plane_unavailable", response.parsed_body.dig("error", "code")
      end
    end
  end
end
