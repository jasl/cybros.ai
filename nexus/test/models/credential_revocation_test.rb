require "test_helper"

# The steward's two product verbs. "Revoke credentials" stops the program or machine now; what
# survives it differs by kind. An agent-profile revoke ends its one address, while a runner's
# machine outlives every credential lineage.
class CredentialRevocationTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @owner = users(:owner)
  end

  test "revoking an agent profile's credentials ends its current connection and address" do
    previous = connect_agent_session(steward: @owner, agent_identifier: "shared", device_name: "Desktop")
    current = connect_agent_session(steward: @owner, agent_identifier: "shared", device_name: "Mobile")
    profile = current.access_token.user

    assert_nil AccessToken.authenticate_token(previous.access_secret)
    assert_nil AccessToken.authenticate_executor_token(previous.executor_access_secret)
    assert_equal current.access_token, AccessToken.authenticate_token(current.access_secret)
    assert_equal current.executor_access_token,
      AccessToken.authenticate_executor_token(current.executor_access_secret)

    assert_equal :revoked, profile.revoke_connection

    assert_nil AccessToken.authenticate_token(current.access_secret)
    assert_nil AccessToken.authenticate_executor_token(current.executor_access_secret)
    assert_predicate current.executor_access_token.task_executor.reload, :revoked?
    assert_predicate current.access_token.refresh_token_family.reload, :revoked?
    assert_nil TaskExecutor.address_for(profile)
    # The profile itself is untouched: reconnecting the same identifier is an
    # ordinary new session, not a restore.
    assert_predicate profile.reload, :active?
    assert_equal :revoked, profile.revoke_connection, "the verb is idempotent"
  end

  test "revoking a runner advances one epoch without touching its credential families" do
    connect_runner(manager: @owner)
    current = connect_runner(manager: @owner)
    runner = @owner.managed_executors.sole
    families = runner.refresh_token_families.order(:id).to_a
    original_epoch = runner.credential_epoch
    runner.update!(last_seen_at: 1.minute.ago)

    assert_equal 2, families.size,
      "the synchronous command must stay constant-time as old lineages accumulate"

    assert_no_queries_match(/\brefresh_token_families\b/i) do
      assert_changes -> { runner.reload.credential_epoch },
        from: original_epoch, to: original_epoch + 1 do
        assert_equal :revoked, runner.revoke_credentials
      end
    end

    assert_predicate runner.reload, :active?, "the machine survives losing its credential"
    assert_nil runner.last_seen_at,
      "the new credential epoch has no successful contact yet"
    assert_equal "workshop-install", runner.registration_identifier
    assert_nil AccessToken.authenticate_executor_token(current.executor_access_secret)
    assert_equal :invalid_grant,
      RefreshTokens::Rotate.call(presented: current.refresh_token).outcome
    families.each do |family|
      assert_nil family.reload.revoked_at,
        "epoch fencing is immediate; durable family marking belongs to convergence"
    end

    assert_equal families.size, RefreshTokenFamily.mark_permanently_fenced.last
    families.each { |family| assert_predicate family.reload, :revoked? }
  end

  test "a fresh device ceremony re-pairs a runner after credential revocation" do
    original = connect_runner(manager: @owner)
    runner = @owner.managed_executors.sole

    assert_equal :revoked, runner.revoke_credentials
    revoked_epoch = runner.reload.credential_epoch
    assert_nil AccessToken.authenticate_executor_token(original.executor_access_secret)

    replacement = connect_runner(manager: @owner)

    assert_equal runner, @owner.managed_executors.sole,
      "reconnection re-pairs the same machine rather than duplicating it"
    assert_equal revoked_epoch + 1, runner.reload.credential_epoch
    assert_equal replacement.executor_access_token,
      AccessToken.authenticate_executor_token(replacement.executor_access_secret)
    assert_equal :rotated,
      RefreshTokens::Rotate.call(presented: replacement.refresh_token).outcome
  end

  test "revoking the runner itself is terminal for the address" do
    result = connect_runner(manager: @owner)
    runner = @owner.managed_executors.sole

    assert_equal :revoked, runner.revoke

    assert_predicate runner.reload, :revoked?
    assert_nil AccessToken.authenticate_executor_token(result.executor_access_secret)
  end

  test "revoking credentials on a terminal runner is an idempotent no-op" do
    connect_runner(manager: @owner)
    runner = @owner.managed_executors.sole
    historical_contact = 1.minute.ago
    runner.update!(last_seen_at: historical_contact)
    assert_equal :revoked, runner.revoke
    terminal_epoch = runner.reload.credential_epoch

    assert_no_changes -> { runner.reload.credential_epoch } do
      assert_equal :revoked, runner.revoke_credentials
    end
    assert_equal terminal_epoch, runner.credential_epoch
    assert_in_delta historical_contact, runner.last_seen_at, 1.second,
      "terminal revoke preserves the address's historical contact sample"
  end

  test "a live session scope excludes revoked lineages" do
    session = connect_agent_session(steward: @owner, agent_identifier: "shared")
    profile = session.access_token.user
    assert_equal 1, profile.refresh_token_families.live.count

    session.access_token.refresh_token_family.revoke

    assert_empty profile.refresh_token_families.live
  end
end
