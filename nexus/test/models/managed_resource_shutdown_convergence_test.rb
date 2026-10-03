require "test_helper"

# Human removal is an O(1) authority transition. Agent Profiles and delivery
# addresses converge independently in bounded batches, each acknowledging the
# durable Human shutdown generation it has safely applied.
class ManagedResourceShutdownConvergenceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @member = users(:member)
  end

  test "remove and restore cannot erase a Runner shutdown episode" do
    connection = connect_runner(
      manager: @member,
      runner_identifier: "restored-before-sweep"
    )
    runner = @member.managed_runners.sole
    public_id = runner.public_id
    original_generation = @member.managed_resource_shutdown_generation
    runner.update!(last_seen_at: 1.minute.ago)

    assert_equal :removed, @member.remove
    assert_equal original_generation + 1,
      @member.reload.managed_resource_shutdown_generation
    assert AccessToken.authenticate_executor_token(connection.executor_access_secret)

    assert_equal :restored, @member.restore
    assert_predicate runner.reload, :shutdown_pending?
    assert_not runner.connection_authority_open?
    assert AccessToken.authenticate_executor_token(connection.executor_access_secret),
      "bound transport remains until graceful convergence reaches its fence"

    TaskExecutor.converge

    runner.reload
    assert_equal public_id, runner.public_id
    assert_equal @member.managed_resource_shutdown_generation,
      runner.applied_human_shutdown_generation
    assert_nil runner.last_seen_at,
      "the fenced epoch's contact sample cannot describe the replacement epoch"
    assert_not_predicate runner, :shutdown_pending?
    assert runner.connection_authority_open?
    assert_nil AccessToken.authenticate_executor_token(connection.executor_access_secret)
    assert_equal :invalid_grant,
      RefreshTokens::Rotate.call(presented: connection.refresh_token).outcome

    replacement = connect_runner(
      manager: @member,
      runner_identifier: runner.runner_identifier
    )
    assert_equal runner, replacement.executor_access_token.task_executor
    assert_equal replacement.executor_access_token,
      AccessToken.authenticate_executor_token(replacement.executor_access_secret)
  end

  test "account-wide Runners are still managed resources of their Human" do
    assert_equal :role_changed, @member.change_role(to: :admin)
    connection = connect_runner(
      manager: @member,
      runner_identifier: "account-farm",
      assignment_scope: :account_wide
    )
    runner = connection.executor_access_token.task_executor

    assert_equal :removed, @member.remove
    TaskExecutor.converge

    assert_nil AccessToken.authenticate_executor_token(connection.executor_access_secret)
    assert_equal @member.reload.managed_resource_shutdown_generation,
      runner.reload.applied_human_shutdown_generation
    assert_predicate runner, :active?
    assert_not runner.connection_authority_open?,
      "an acknowledged address remains unavailable while its manager is removed"
  end

  # The widened HUMAN_SHUTDOWN_PENDING_SQL is what makes human removal reach a provider at all: the
  # same fence, the same acknowledgement.
  test "a tools provider is a managed resource of its Human and converges on removal" do
    connection = connect_runner(
      manager: @member, runner_identifier: "provider-farm",
      assignment_scope: :user_private, executor_kind: :tools_provider
    )
    provider = connection.executor_access_token.task_executor
    assert_predicate provider, :tools_provider?

    assert_equal :removed, @member.remove
    assert_predicate provider.reload, :shutdown_pending?
    assert AccessToken.authenticate_executor_token(connection.executor_access_secret),
      "bound transport remains until convergence reaches its fence"

    TaskExecutor.converge

    assert_nil AccessToken.authenticate_executor_token(connection.executor_access_secret)
    assert_equal @member.reload.managed_resource_shutdown_generation,
      provider.reload.applied_human_shutdown_generation
    assert_predicate provider, :active?
    assert_not provider.connection_authority_open?
  end

  test "an address without a credential family still acknowledges shutdown" do
    runner = @account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Never connected",
      runner_identifier: "no-family",
      manager: @member,
      assignment_scope: :user_private
    )
    original_epoch = runner.credential_epoch

    assert_equal :removed, @member.remove
    assert_equal :restored, @member.restore
    TaskExecutor.converge

    runner.reload
    assert_equal original_epoch + 1, runner.credential_epoch
    assert_equal @member.managed_resource_shutdown_generation,
      runner.applied_human_shutdown_generation
  end

  test "an Agent Profile with no address converges independently" do
    profile = create_agent_member(
      steward: @member,
      agent_identifier: "conversation-only-agent"
    )
    original_authority = profile.authority_generation
    assert_nil TaskExecutor.address_for(profile)

    assert_equal :removed, @member.remove
    assert_equal :restored, @member.restore
    assert_not profile.reload.steward_live?

    assert_equal 1, User.converge[:converged]

    profile.reload
    assert_predicate profile, :removed?
    assert_equal original_authority + 1, profile.authority_generation
    assert_equal @member.managed_resource_shutdown_generation,
      profile.applied_steward_shutdown_generation
    assert profile.steward_live?,
      "the shutdown is acknowledged even though explicit reconnect is still required"
  end

  test "Agent membership and executor transport converge on separate axes" do
    identifier = "agent-with-address"
    connection = connect_agent_session(
      steward: @member,
      agent_identifier: identifier
    )
    profile = @member.stewarded_agents.find_by!(agent_identifier: identifier)
    executor = connection.executor_access_token.task_executor

    assert_equal :removed, @member.remove
    assert_equal :restored, @member.restore
    assert_nil AccessToken.authenticate_token(connection.access_secret),
      "member authority cannot revive before Profile convergence"
    assert AccessToken.authenticate_executor_token(connection.executor_access_secret),
      "transport remains available for graceful stopping"

    assert_equal 1, User.converge[:converged]
    assert_predicate profile.reload, :removed?
    replacement_grant = DeviceAuthorizations::Issue.call(
      account: @account,
      agent_identifier: identifier,
      agent_display_name: "Reconnected agent",
      requested_executor_display_name: "Reconnected app"
    ).authorization
    assert_equal :shutdown_pending,
      DeviceAuthorizations::Connect.call(
        authorization: replacement_grant,
        connector: @member
      ).outcome

    TaskExecutor.converge

    assert_nil AccessToken.authenticate_executor_token(connection.executor_access_secret)
    assert_equal @member.managed_resource_shutdown_generation,
      executor.reload.applied_human_shutdown_generation

    assert_equal :connected,
      DeviceAuthorizations::Connect.call(
        authorization: replacement_grant.reload,
        connector: @member
      ).outcome
    replacement = DeviceAuthorizations::Consume.call(
      authorization: replacement_grant.reload
    )
    assert_equal :minted, replacement.outcome
    assert_predicate profile.reload, :active?
    assert_equal executor, replacement.executor_access_token.task_executor
  end

  # The batch bounds SCANNED source rows (M7): the generation mismatch is a
  # cross-row comparison no index can serve, so clean rows consume budget and
  # the cursor walks past them. The continuation chain — exactly what
  # Users::ConvergeJob drives — is what finishes the corpus.
  test "each User invocation scans at most its requested batch and the chain converges all" do
    profiles = 2.times.map do |index|
      create_agent_member(
        steward: @member,
        agent_identifier: "profile-batch-#{index}"
      )
    end
    assert_equal :removed, @member.remove

    converged = 0
    cursor = 0
    50.times do
      result = User.converge(batch_size: 1, after_id: cursor)
      assert_operator result[:scanned], :<=, 1
      converged += result[:converged]
      cursor = result.cursor
      break unless result.more?
    end

    assert_equal 2, converged
    assert profiles.all? { _1.reload.removed? }
    assert_equal 0, User.converge(batch_size: 10_000)[:converged]
  end

  test "each TaskExecutor invocation scans at most its requested batch and the chain acknowledges all" do
    2.times do |index|
      @account.task_executors.create!(
        executor_kind: :runner,
        display_name: "Batch #{index}",
        runner_identifier: "batch-#{index}",
        manager: @member,
        assignment_scope: :user_private
      )
    end
    assert_equal :removed, @member.remove

    shutdown_cursor = 0
    reap_cursor = 0
    50.times do
      result = TaskExecutor.converge(
        batch_size: 1,
        shutdown_after_id: shutdown_cursor,
        reap_after_id: reap_cursor
      )
      assert_operator result[:scanned], :<=, 1
      shutdown_cursor = result.cursor.first
      reap_cursor = result.cursor.last
      break unless result.more?
    end

    assert_equal 0, @member.managed_runners.reload.count(&:shutdown_pending?)
  end

  test "mixed shutdown and reap work each own a bounded share and both backlogs drain" do
    pending = 3.times.map do |index|
      @account.task_executors.create!(
        executor_kind: :runner,
        display_name: "Pending shutdown #{index}",
        runner_identifier: "mixed-pending-#{index}",
        manager: @member,
        assignment_scope: :user_private
      )
    end
    reapable = 2.times.map do |index|
      runner = @account.task_executors.create!(
        executor_kind: :runner,
        display_name: "Reapable #{index}",
        runner_identifier: "mixed-reap-#{index}",
        manager: @owner,
        assignment_scope: :user_private
      )
      runner.revoke
      runner
    end
    assert_equal :removed, @member.remove

    first = TaskExecutor.converge(batch_size: 2)
    assert_operator first[:scanned], :<=, 2
    assert_equal 1, first[:reaped],
      "the reap share is reserved so a shutdown backlog cannot starve it"

    shutdown_cursor = first.cursor.first
    reap_cursor = first.cursor.last
    40.times do
      result = TaskExecutor.converge(
        batch_size: 2,
        shutdown_after_id: shutdown_cursor,
        reap_after_id: reap_cursor
      )
      assert_operator result[:scanned], :<=, 2
      shutdown_cursor = result.cursor.first
      reap_cursor = result.cursor.last
      break unless result.more?
    end

    assert pending.none? { _1.reload.shutdown_pending? }
    assert_equal 0, TaskExecutor.where(id: reapable.map(&:id)).count
    idle = TaskExecutor.converge(batch_size: 10_000)
    assert_equal 0, idle[:converged] + idle[:reaped]
  end

  test "a stale generation candidate cannot acknowledge a newer episode" do
    runner = @account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Repeated shutdown",
      runner_identifier: "repeated-shutdown",
      manager: @member,
      assignment_scope: :user_private
    )
    stale_applied = runner.applied_human_shutdown_generation

    assert_equal :removed, @member.remove
    stale_generation = @member.managed_resource_shutdown_generation
    assert_equal :restored, @member.restore
    assert_equal :removed, @member.remove

    assert_equal :converged,
      runner.converge_human_shutdown(
        expected_human_id: @member.id,
        expected_generation: stale_generation,
        expected_applied_generation: stale_applied
      )
    assert_equal stale_generation,
      runner.reload.applied_human_shutdown_generation
    assert_predicate runner, :shutdown_pending?,
      "the stale worker may acknowledge only its frozen generation"

    TaskExecutor.converge
    assert_equal @member.managed_resource_shutdown_generation,
      runner.reload.applied_human_shutdown_generation
  end

  test "a stale Profile worker also applies only its frozen generation" do
    profile = create_agent_member(
      steward: @member,
      agent_identifier: "repeated-profile-shutdown"
    )
    stale_applied = profile.applied_steward_shutdown_generation

    assert_equal :removed, @member.remove
    stale_generation = @member.managed_resource_shutdown_generation
    assert_equal :restored, @member.restore
    assert_equal :removed, @member.remove

    assert_equal :converged,
      profile.converge_steward_shutdown(
        expected_steward_id: @member.id,
        expected_generation: stale_generation,
        expected_applied_generation: stale_applied
      )
    assert_equal stale_generation,
      profile.reload.applied_steward_shutdown_generation
    assert_not profile.steward_live?

    assert_equal 1, User.converge[:converged]
    assert_equal @member.managed_resource_shutdown_generation,
      profile.reload.applied_steward_shutdown_generation
  end

  test "runner lineages reach the permanent fence like every other lineage" do
    connection = connect_runner(manager: @owner, runner_identifier: "fenced")
    runner = @owner.managed_runners.find_by!(runner_identifier: "fenced")
    family = connection.executor_access_token.refresh_token_family
    advance_credential_epoch(runner)

    assert_equal 1, RefreshTokenFamily.mark_permanently_fenced.last
    assert_predicate family.reload, :revoked?
  end
end
