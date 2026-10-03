require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class ModelProvidersLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  test "a policy mutation locks its policy row" do
    account = accounts(:cybros)
    ModelProviders::EnableLane.call(
      account: account, provider_id: "openai_api",
      expected_lock_version: nil
    )
    policy = ModelProviderPolicy.find_by!(account: account, provider_id: "openai_api")

    sequences = assert_ladder_order("disable lane") do
      result = ModelProviders::DisableLane.call(
        account: account, provider_id: "openai_api",
        expected_lock_version: policy.lock_version
      )
      assert_predicate result, :done?
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "model_provider_policies"
  end

  test "an OAuth claim descends policy then session" do
    account = accounts(:cybros)
    ModelProviders::EnableLane.call(
      account: account, provider_id: ModelProviders::CodexAuthorization::PROVIDER_ID,
      expected_lock_version: nil
    )
    session = ModelProviders::CodexAuthorization::AcceptSession.call(
      account: account, issuing_user: users(:owner), kind: "device_start"
    ).session

    sequences = assert_ladder_order("OAuth claim") do
      result = ModelProviders::CodexAuthorization::Claim.call(session: session)
      assert_predicate result, :claimed?
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[model_provider_policies model_provider_oauth_sessions]
    assert_not_includes sequences.flatten, "model_provider_oauth_tasks",
      "the new task is inserted, not explicitly relocked"
  end

  test "the stale OAuth dispatch sweep locks the session before settling its task" do
    account = accounts(:cybros)
    owner = users(:owner)
    provider_id = ModelProviders::CodexAuthorization::PROVIDER_ID
    ModelProviders::EnableLane.call(
      account: account, provider_id: provider_id, expected_lock_version: nil
    )
    device = ModelProviders::CodexAuthorization::AcceptSession.call(
      account: account, issuing_user: owner, kind: "device_start"
    ).session
    device.terminalize(state: "revoked", outcome: "operator_revoked")
    ModelProviderCredential.create!(
      account: account, provider_id: provider_id, material_kind: "oauth_tokens",
      secret: "guard-at", refresh_secret: "guard-rt",
      authorization_lineage_id: SecureRandom.uuid, generation: 1,
      expires_at: 1.hour.from_now
    )
    refresh = ModelProviders::CodexAuthorization::AcceptSession.call(
      account: account, issuing_user: owner, kind: "token_refresh"
    ).session
    task = ModelProviders::CodexAuthorization::Claim.call(session: refresh).task

    sequences = assert_ladder_order("stale OAuth dispatch") do
      assert_equal 1,
        ModelProviders::CodexAuthorization::Sweeps
          .seal_stale_dispatches(now: task.deadline_at + 1)
    end

    assert_equal "model_provider_oauth_sessions", sequences.first.first,
      "the parent Session is the sweep transaction's first explicit row lock"
    assert_equal ModelProviderOAuthTask::SPENT, task.reload.state
    assert_equal "failed", refresh.reload.state
  end

  test "an api key rotation locks its credential lane" do
    account = accounts(:cybros)
    # A fresh install is the unique index's business (ladder rung 1); the
    # rotation over the existing row is where the lane lock lives.
    first = ModelProviders::SetAPIKey.call(
      account: account, provider_id: "openai_api", api_key: "sk-guard"
    )
    assert_predicate first, :done?

    sequences = assert_ladder_order("api key rotation") do
      result = ModelProviders::SetAPIKey.call(
        account: account, provider_id: "openai_api", api_key: "sk-guard-rotated"
      )
      assert_predicate result, :done?
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "model_provider_credentials"
  end

  test "an operator api key save locks policy before its credential" do
    account = accounts(:cybros)
    ModelProviders::ConfigureAPIKey.call(account: account, provider_id: "openai_api", api_key: "test-first")

    sequences = assert_ladder_order("operator api key save") do
      result = ModelProviders::ConfigureAPIKey.call(account: account, provider_id: "openai_api", api_key: "test-second")
      assert_predicate result, :done?
    end

    # create_or_find_by!'s savepoints divide the recorder's groups, but the
    # outer command transaction retains both locks until it commits.
    collapsed = sequences.flatten.chunk_while { |a, b| a == b }.map(&:first)
    assert_equal %w[model_provider_policies model_provider_credentials], collapsed
  end

  test "OAuth credential installation locks policy session task and credential in order" do
    account = accounts(:cybros)
    provider_id = ModelProviders::CodexAuthorization::PROVIDER_ID
    ModelProviders::EnableLane.call(account: account, provider_id: provider_id, expected_lock_version: nil)
    ModelProviders::InstallOAuthPair.call(account: account, provider_id: provider_id,
      access_token: "test-access", refresh_token: "test-refresh", lineage_id: SecureRandom.uuid_v7,
      expected_generation: nil, expires_at: 1.hour.from_now)
    session = ModelProviders::CodexAuthorization::AcceptSession.call(
      account: account, issuing_user: users(:owner), kind: "token_refresh"
    ).session
    task = ModelProviders::CodexAuthorization::Claim.call(session: session).task
    outcome = ModelProviders::CodexAuthorization::Responses.token_refresh(status: 200,
      body: { access_token: "rotated-access", refresh_token: "rotated-refresh", id_token: "h.e30.s", expires_in: 3600 }.to_json)

    sequences = assert_ladder_order("OAuth credential installation") do
      result = ModelProviders::CodexAuthorization::InstallCredential.call(
        session: session, task: task, outcome: outcome, normalized_status: "http_200"
      )
      assert_predicate result, :installed?
    end

    assert_includes sequences, %w[
      model_provider_policies model_provider_oauth_sessions model_provider_oauth_tasks model_provider_credentials
    ]
  end
end
