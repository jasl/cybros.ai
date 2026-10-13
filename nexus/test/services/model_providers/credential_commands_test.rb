require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# C2-2 WP3c: transport-neutral credential primitives. API-key set/rotate/
# remove for the api_key lane; OAuth install (lineage/generation CAS),
# reauthorization mark, and clear as the primitives C2-OAuth will
# exclusively consume. Credential CAS uses only the credential's own
# server-owned generation.
class ModelProviders::CredentialCommandsTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_a_concurrent_api_key_creator_retries_and_observes_the_committed_winner,
    :test_concurrent_oauth_device_starts_return_one_stable_stale_outcome

  setup do
    @account = accounts(:cybros)
  end

  test "set installs an api key; rotate replaces it and advances its credential generation" do
    result = ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "sk-one")

    assert_predicate result, :done?
    credential = ModelProviderCredential.find_by!(account: @account, provider_id: "openai_api")
    assert_equal "sk-one", credential.secret

    rotated = ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "sk-two")
    assert_predicate rotated, :done?
    assert_equal "sk-two", credential.reload.secret
    assert_equal credential.generation, 1
    assert_not_nil credential.rotated_at
  end

  test "setting the same normalized api key is a no-op" do
    ModelProviders::SetAPIKey.call(
      account: @account, provider_id: "openai_api", api_key: "sk-one"
    )
    credential = ModelProviderCredential.find_by!(account: @account, provider_id: "openai_api")
    before = [credential.generation, credential.updated_at]

    replay = ModelProviders::SetAPIKey.call(
      account: @account, provider_id: "openai_api", api_key: "  sk-one  "
    )

    assert_equal :noop, replay.outcome
    assert_equal before, [credential.reload.generation, credential.updated_at]
  end

  test "a concurrent api key creator retries and observes the committed winner" do
    held = hold_uncommitted_credential(
      provider_id: "openai_api", material_kind: "api_key", secret: "sk-winner"
    )
    call = start_database_call do
      ModelProviders::SetAPIKey.call(
        account: @account, provider_id: "openai_api", api_key: "sk-winner"
      )
    end

    wait_until_waiting_on_lock(call.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(call)
    call = nil

    assert_equal :noop, result.outcome
    assert_equal "sk-winner",
      ModelProviderCredential.find_by!(account: @account, provider_id: "openai_api").secret
  ensure
    release_row_lock(held) if held
    stop_database_call(call) if call
    cleanup_credential_race("openai_api")
  end

  test "a blank api key is invalid before SQL and set refuses an oauth lane" do
    assert_equal :invalid,
      ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "  ").outcome

    install_oauth
    assert_equal :material_kind_conflict,
      ModelProviders::SetAPIKey.call(account: @account, provider_id: "codex_subscription", api_key: "sk").outcome
  end

  test "remove deletes the api-key row; removing an absent lane is not_found" do
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "sk-one")

    result = ModelProviders::RemoveAPIKey.call(account: @account, provider_id: "openai_api")

    assert_predicate result, :done?
    assert_nil ModelProviderCredential.find_by(account: @account, provider_id: "openai_api")

    assert_equal :not_found,
      ModelProviders::RemoveAPIKey.call(account: @account, provider_id: "openai_api").outcome
  end

  def install_oauth(expected_generation: nil, lineage: nil, access: "synthetic-access")
    ModelProviders::InstallOAuthPair.call(
      account: @account, provider_id: "codex_subscription",
      access_token: access, refresh_token: "synthetic-refresh",
      lineage_id: lineage || SecureRandom.uuid_v7,
      expected_generation: expected_generation,
      expires_at: 4.hours.from_now
    )
  end

  test "a device-start install creates the pair; a refresh install is lineage-and-generation CAS guarded" do
    created = install_oauth
    assert_predicate created, :done?
    credential = ModelProviderCredential.find_by!(account: @account, provider_id: "codex_subscription")
    assert_equal 0, credential.generation

    refreshed = install_oauth(
      expected_generation: 0, lineage: credential.authorization_lineage_id, access: "rotated-access"
    )
    assert_predicate refreshed, :done?
    assert_equal 1, credential.reload.generation
    assert_equal "rotated-access", credential.secret

    stale = install_oauth(
      expected_generation: 0, lineage: credential.authorization_lineage_id, access: "poison"
    )
    assert_equal :stale, stale.outcome
    assert_equal "rotated-access", credential.reload.secret,
      "an ambiguous or stale continuation can never overwrite a newer success"

    wrong_lineage = install_oauth(expected_generation: 1, lineage: SecureRandom.uuid_v7)
    assert_equal :stale, wrong_lineage.outcome
  end

  test "concurrent oauth device starts return one stable stale outcome" do
    winner_lineage = SecureRandom.uuid_v7
    held = hold_uncommitted_credential(
      provider_id: "codex_subscription", material_kind: "oauth_tokens",
      secret: "winner-access", refresh_secret: "winner-refresh",
      authorization_lineage_id: winner_lineage, expires_at: 4.hours.from_now
    )
    call = start_database_call do
      install_oauth(lineage: SecureRandom.uuid_v7, access: "loser-access")
    end

    wait_until_waiting_on_lock(call.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(call)
    call = nil

    assert_equal :stale, result.outcome
    credential = ModelProviderCredential.find_by!(
      account: @account, provider_id: "codex_subscription"
    )
    assert_equal winner_lineage, credential.authorization_lineage_id
    assert_equal "winner-access", credential.secret
  ensure
    release_row_lock(held) if held
    stop_database_call(call) if call
    cleanup_credential_race("codex_subscription")
  end

  test "the reauthorization mark is CAS guarded and install clears it" do
    install_oauth
    credential = ModelProviderCredential.find_by!(account: @account, provider_id: "codex_subscription")
    marked = ModelProviders::MarkReauthorizationRequired.call(
      account: @account, provider_id: "codex_subscription",
      lineage_id: credential.authorization_lineage_id, expected_generation: credential.generation,
      reason: "refresh_rejected"
    )
    assert_predicate marked, :done?
    assert credential.reload.reauthorization_required

    replay = ModelProviders::MarkReauthorizationRequired.call(
      account: @account, provider_id: "codex_subscription",
      lineage_id: credential.authorization_lineage_id, expected_generation: credential.generation,
      reason: "refresh_rejected"
    )
    assert_equal :noop, replay.outcome

    cleared = install_oauth(
      expected_generation: credential.generation, lineage: credential.authorization_lineage_id
    )
    assert_predicate cleared, :done?
    refute credential.reload.reauthorization_required
  end

  test "clear deletes the oauth pair" do
    install_oauth

    result = ModelProviders::ClearOAuth.call(account: @account, provider_id: "codex_subscription")

    assert_predicate result, :done?
    assert_nil ModelProviderCredential.find_by(account: @account, provider_id: "codex_subscription")
  end

  private

    def hold_uncommitted_credential(attributes)
      ready = Queue.new
      release = Queue.new
      errors = Queue.new
      thread = Thread.new do
        Thread.current.report_on_exception = false
        signaled = false
        ApplicationRecord.connection_pool.with_connection do |connection|
          ModelProviderCredential.transaction do
            ModelProviderCredential.create!(account: @account, **attributes)
            ready << connection.select_value("SELECT pg_backend_pid()").to_i
            signaled = true
            release.pop
          end
        end
      rescue StandardError => error
        ready << error unless signaled
        errors << error
      end

      pid = Timeout.timeout(RowLockTestHelper::ROW_LOCK_WAIT_TIMEOUT) { ready.pop }
      raise pid if pid.is_a?(Exception)

      RowLockTestHelper::HeldRowLock.new(thread: thread, pid: pid, release: release, errors: errors)
    end

    def cleanup_credential_race(provider_id)
      ModelProviderCredential.where(account: @account, provider_id: provider_id).delete_all
    end
end
