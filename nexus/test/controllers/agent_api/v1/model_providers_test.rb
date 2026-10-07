require "test_helper"

class AgentAPI::V1::ModelProvidersTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @account = accounts(:cybros)
    @token = create_access_token_fixture(user: @human, name: "Member")
  end

  def auth = { "Authorization" => "Bearer #{@token.secret}" }

  def lanes
    get "/agent_api/v1/model_providers", headers: auth
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

  test "member discovery remains readable while provider writes are absent" do
    assert_not_empty lanes

    %w[lane api_key].each do |resource|
      put "/agent_api/v1/model_providers/openrouter/#{resource}",
        params: { command: { enabled: true, api_key: "unused" } }, as: :json, headers: auth
      assert_response :not_found
    end
    delete "/agent_api/v1/model_providers/openrouter/api_key", headers: auth
    assert_response :not_found
    assert_nil ModelProviderCredential.find_by(account: @account, provider_id: "openrouter")
    assert_nil ModelProviderConfig.find_by(account: @account, provider_id: "openrouter")
  end

  test "discovery requires the member plane" do
    get "/agent_api/v1/model_providers"
    assert_response :unauthorized

    platform = create_access_token_fixture(user: users(:owner), name: "Operator", plane: :platform)
    get "/agent_api/v1/model_providers", headers: { "Authorization" => "Bearer #{platform.secret}" }
    assert_response :unauthorized
  end
end
