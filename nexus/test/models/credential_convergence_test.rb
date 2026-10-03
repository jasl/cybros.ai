require "test_helper"

class CredentialConvergenceTest < ActiveSupport::TestCase
  setup do
    @member = create_agent_member(
      display_name: "Convergence",
      agent_identifier: "install-convergence"
    )
    @executor = @member.task_executors.create!(
      account: @member.account,
      executor_kind: :agent_application,
      display_name: "Convergence app"
    )
  end

  test "family and descendant convergence advances one bounded batch per invocation" do
    now = Time.current
    family = build_family
    accesses = 3.times.map { build_access(family:, plane: :executor_transport) }
    refreshes = accesses.each_with_index.map do |access, index|
      build_refresh(family:, access:, consumed_at: (now if index < 2))
    end

    assert accesses.all?(&:executor_usable?)
    family.revoke(now:)
    assert accesses.none?(&:executor_usable?), "the family authority fences access before markers run"
    assert_predicate refreshes.last, :current?
    assert_not_predicate family, :rotation_acceptable?,
      "the family authority fences refresh before markers run"
    assert accesses.all? { |access| access.revoked_at.nil? }
    assert refreshes.all? { |refresh| refresh.revoked_at.nil? }

    # The marker walk is now a cursor-carrying source window: each
    # invocation scans at most batch_size rows, and the continuation chain —
    # exactly what the converge jobs drive — is what finishes the corpus.
    access_marked = drain_converge(batch_size: 2) do |cursor|
      AccessToken.converge(now:, batch_size: 2, marker_after_id: cursor)
    end
    refresh_marked = drain_converge(
      batch_size: 2,
      cursor: [nil, 0]
    ) do |lapsed_cursor, marker_cursor|
      RefreshToken.converge(
        now:, batch_size: 2,
        lapsed_after: lapsed_cursor,
        marker_after_id: marker_cursor
      )
    end
    assert_equal 3, access_marked
    assert_equal 3, refresh_marked
    assert_equal 3, family.access_tokens.where.not(revoked_at: nil).count
    assert_equal 3, family.refresh_tokens.where.not(revoked_at: nil).count

    first_access = family.access_tokens.where.not(revoked_at: nil).order(:id).first
    first_mark = first_access.revoked_at

    idle = AccessToken.converge(now:, batch_size: 10_000)
    assert_equal 0, idle[:marked] + idle[:reaped]
    assert_equal first_mark, first_access.reload.revoked_at,
      "a second pass never re-marks an already fenced credential"
  end

  test "access convergence shares one total batch fairly across reaping and marking" do
    now = Time.current
    stale_family = build_family
    stale = 2.times.map do
      build_access(
        family: stale_family,
        expires_at: now - AccessToken::REAP_RETENTION - 1.minute
      )
    end

    marker_member = create_agent_member(
      display_name: "Access marker",
      agent_identifier: "access-marker"
    )
    marker_family = build_family(
      user: marker_member,
      task_executor: address_for(marker_member)
    )
    to_mark = 2.times.map { build_access(family: marker_family) }
    marker_family.revoke(now:)

    # The reap quota is reserved up front, so a marker backlog can never
    # starve reclamation: the very first bounded call must reap.
    first = AccessToken.converge(now:, batch_size: 2)
    assert_equal 1, first[:reaped]
    assert_operator first[:scanned], :<=, 2

    marked = first[:marked] + drain_converge(batch_size: 2, cursor: first.cursor) do |cursor|
      AccessToken.converge(now:, batch_size: 2, marker_after_id: cursor)
    end
    assert stale.none? { |access| AccessToken.exists?(access.id) }
    assert_equal 2, marked
    assert to_mark.all? { |access| access.reload.revoked? }
    idle = AccessToken.converge(now:, batch_size: 10_000)
    assert_equal 0, idle[:marked] + idle[:reaped]
  end

  test "refresh convergence shares one total batch fairly across reaping and marking" do
    now = Time.current
    stale_family = build_family
    stale_access = build_access(family: stale_family)
    stale = 2.times.map do
      build_refresh(
        family: stale_family,
        access: stale_access,
        consumed_at: now - RefreshToken::EVIDENCE_RETENTION - 1.minute
      )
    end

    marker_member = create_agent_member(
      display_name: "Refresh marker",
      agent_identifier: "refresh-marker"
    )
    marker_family = build_family(
      user: marker_member,
      task_executor: address_for(marker_member)
    )
    marker_access = build_access(family: marker_family)
    to_mark = 2.times.map do
      build_refresh(
        family: marker_family,
        access: marker_access,
        consumed_at: now
      )
    end
    marker_family.revoke(now:)

    first = RefreshToken.converge(now:, batch_size: 2)
    assert_equal 1, first[:reaped], "the reserved reap quota fires on the first bounded call"
    assert_operator first[:scanned], :<=, 2

    marked = first[:marked] + drain_converge(
      batch_size: 2,
      cursor: first.cursor
    ) do |lapsed_cursor, marker_cursor|
      RefreshToken.converge(
        now:, batch_size: 2,
        lapsed_after: lapsed_cursor,
        marker_after_id: marker_cursor
      )
    end
    assert stale.none? { |refresh| RefreshToken.exists?(refresh.id) }
    assert_equal 2, marked
    assert to_mark.all? { |refresh| refresh.reload.revoked_at.present? }
    idle = RefreshToken.converge(now:, batch_size: 10_000)
    assert_equal 0, idle[:marked] + idle[:reaped]
  end

  test "family convergence shares one total batch fairly across reaping and marking" do
    now = Time.current
    stale = 2.times.map do |index|
      member = create_agent_member(
        display_name: "Stale family #{index}",
        agent_identifier: "stale-family-#{index}"
      )
      build_family(
        user: member,
        task_executor: address_for(member),
        last_used_at: reapable_lapse(now) - 1.minute
      )
    end
    to_mark = 2.times.map do |index|
      member = create_agent_member(
        display_name: "Fenced family #{index}",
        agent_identifier: "fenced-family-#{index}"
      )
      executor = address_for(member)
      family = build_family(user: member, task_executor: executor)
      executor.revoke
      family
    end

    first = RefreshTokenFamily.converge(now:, batch_size: 2)
    assert_equal 1, first[:reaped], "the reserved reap quota fires on the first bounded call"
    assert_operator first[:scanned], :<=, 2

    marked = first[:marked] + drain_converge(
      batch_size: 2,
      cursor: first.cursor
    ) do |marker_cursor, reap_cursor|
      RefreshTokenFamily.converge(
        now:, batch_size: 2,
        marker_after_id: marker_cursor,
        reap_after: reap_cursor
      )
    end
    assert stale.none? { |family| RefreshTokenFamily.exists?(family.id) }
    assert_equal 2, marked
    assert to_mark.all? { |family| family.reload.revoked? }
    idle = RefreshTokenFamily.converge(now:, batch_size: 10_000)
    assert_equal 0, idle[:marked] + idle[:reaped]
  end

  test "family authority markers are bounded and ignore reversible steward inactivity" do
    member = create_agent_member(
      steward: users(:member),
      display_name: "Stewarded",
      agent_identifier: "install-stewarded"
    )
    family = build_family(user: member, task_executor: address_for(member))
    access = build_access(family:)
    refresh = build_refresh(family:, access:)

    users(:member).suspend
    assert_not access.reload.usable?
    # The lineage stays rotatable: every lineage is executor-bound now, and a bound lineage's
    # authority is its address, which a steward's suspension does not touch. Member authority is
    # re-checked where it belongs — in RefreshTokens::Rotate, not in this predicate.
    assert_predicate refresh.reload, :current?
    assert_predicate family, :rotation_acceptable?
    assert_equal 0, RefreshTokenFamily.mark_permanently_fenced(batch_size: 10_000).last
    assert_equal 0, AccessToken.mark_permanently_fenced(batch_size: 10_000).last
    assert_nil family.reload.revoked_at
    assert_nil access.reload.revoked_at

    users(:member).reload.reactivate
    assert access.reload.usable?
    assert_predicate refresh.reload, :current?
    assert_predicate family.reload, :rotation_acceptable?

    # Profile removal preserves the address and fences its current epoch.
    families = 3.times.map do |index|
      owner = create_agent_member(
        display_name: "Ended #{index}",
        agent_identifier: "install-ended-#{index}"
      )
      build_family(user: owner, task_executor: address_for(owner))
    end
    families.each { |candidate| candidate.user.remove }

    assert families.none? { |candidate| candidate.reload.rotation_acceptable? }
    marked = drain_converge(
      batch_size: 2,
      cursor: [0, RefreshTokenFamily::Convergence::REAP_CURSOR_START]
    ) do |marker_cursor, reap_cursor|
      RefreshTokenFamily.converge(
        batch_size: 2,
        marker_after_id: marker_cursor,
        reap_after: reap_cursor
      )
    end
    assert_equal 3, marked
    assert families.all? { |candidate| candidate.reload.revoked? }
    idle = RefreshTokenFamily.converge(batch_size: 10_000)
    assert_equal 0, idle[:marked] + idle[:reaped]
  end

  test "an executor epoch fence converges a device access marker" do
    credential = create_bound_credential(executor: @executor)
    assert credential.token.executor_usable?

    advance_credential_epoch(@executor)

    assert_not credential.token.reload.executor_usable?
    assert_nil credential.token.revoked_at
    assert_equal 1, AccessToken.mark_permanently_fenced(batch_size: 10_000).last
    assert credential.token.reload.revoked?
  end

  test "Agent removal converges executor-bound transport credential markers" do
    credential = create_bound_credential(executor: @executor)
    family = credential.token.refresh_token_family

    @member.remove

    assert_nil AccessToken.authenticate_token(credential.secret)
    assert_nil AccessToken.authenticate_executor_token(credential.secret)
    assert_not family.reload.rotation_acceptable?
    assert_equal 1, RefreshTokenFamily.mark_permanently_fenced(batch_size: 10_000).last
    assert_equal 1, AccessToken.mark_permanently_fenced(batch_size: 10_000).last
    assert_not_nil family.reload.revoked_at
    assert_not_nil credential.token.reload.revoked_at
  end

  test "consumed refresh evidence follows its own retention clock in bounded batches" do
    now = Time.current
    family = build_family(last_used_at: now)
    access = build_access(family:)
    stale = 3.times.map do
      build_refresh(
        family:,
        access:,
        consumed_at: now - RefreshToken::EVIDENCE_RETENTION - 1.minute
      )
    end
    recent = build_refresh(
      family:,
      access:,
      consumed_at: now - RefreshToken::EVIDENCE_RETENTION + 1.minute
    )
    current = build_refresh(family:, access:)

    assert_equal 2, RefreshToken.reap(now:, batch_size: 2)[:reaped]
    assert_equal 1, stale.count { |refresh| RefreshToken.exists?(refresh.id) }
    assert_equal 1, RefreshToken.reap(now:, batch_size: 2)[:reaped]
    assert_equal 0, RefreshToken.reap(now:, batch_size: 2)[:reaped]

    assert stale.none? { |refresh| RefreshToken.exists?(refresh.id) }
    assert RefreshToken.exists?(recent.id)
    assert RefreshToken.exists?(current.id)
    assert RefreshTokenFamily.exists?(family.id),
      "a continually rotating family must not retain all of its consumed evidence"
  end

  test "revoked refresh evidence follows its own retention clock" do
    now = Time.current
    family = build_family(last_used_at: now)
    access = build_access(family:)
    stale = build_refresh(
      family:,
      access:,
      revoked_at: now - RefreshToken::EVIDENCE_RETENTION - 1.minute
    )
    recent = build_refresh(
      family:,
      access:,
      revoked_at: now - RefreshToken::EVIDENCE_RETENTION + 1.minute
    )

    assert_equal 1, RefreshToken.reap(now:, batch_size: 2)[:reaped]
    assert_not RefreshToken.exists?(stale.id)
    assert RefreshToken.exists?(recent.id)
    assert RefreshTokenFamily.exists?(family.id)
  end

  test "current refresh tokens and the family tombstone retain the lapse ladder" do
    now = Time.current
    family = build_family(last_used_at: reapable_lapse(now) - 1.minute)
    access = build_access(
      family:,
      expires_at: now - AccessToken::REAP_RETENTION - 1.minute
    )
    current = build_refresh(family:, access:)
    # A later connection on the same durable address advances its epoch
    # before creating the next lineage.
    advance_credential_epoch(@executor)
    retained_family = build_family(last_used_at: reapable_lapse(now) + 1.minute)
    retained_access = build_access(
      family: retained_family,
      expires_at: now - AccessToken::REAP_RETENTION + 1.minute
    )
    retained_refresh = build_refresh(family: retained_family, access: retained_access)

    assert_equal 1, RefreshToken.reap(now:, batch_size: 2)[:reaped]
    assert_not RefreshToken.exists?(current.id)
    assert RefreshToken.exists?(retained_refresh.id)
    assert_equal 0, RefreshTokenFamily.reap(now:, batch_size: 2)

    assert_equal 0, RefreshToken.reap(now:, batch_size: 2)[:reaped]
    assert_equal 0, RefreshTokenFamily.reap(now:, batch_size: 2),
      "the retained access-token audit row keeps the family tombstone"

    assert_equal 1, AccessToken.reap(now:, batch_size: 2)
    assert AccessToken.exists?(retained_access.id)
    assert_equal 1, RefreshTokenFamily.reap(now:, batch_size: 2)
    assert_not RefreshTokenFamily.exists?(family.id)
    assert RefreshTokenFamily.exists?(retained_family.id)
  end

  test "access-token reaping advances one bounded batch per invocation" do
    now = Time.current
    family = build_family
    accesses = 3.times.map do
      build_access(
        family:,
        expires_at: now - AccessToken::REAP_RETENTION - 1.minute
      )
    end

    assert_equal 2, AccessToken.reap(now:, batch_size: 2)
    assert_equal 1, accesses.count { |access| AccessToken.exists?(access.id) }
    assert_equal 1, AccessToken.reap(now:, batch_size: 2)
    assert_equal 0, AccessToken.reap(now:, batch_size: 2)
    assert accesses.none? { |access| AccessToken.exists?(access.id) }
  end

  test "family reaping advances one bounded batch per invocation" do
    now = Time.current
    families = 3.times.map do |index|
      member = create_agent_member(
        display_name: "Reapable family #{index}",
        agent_identifier: "reapable-family-#{index}"
      )
      build_family(
        user: member,
        task_executor: address_for(member),
        last_used_at: reapable_lapse(now) - 1.minute
      )
    end

    assert_equal 2, RefreshTokenFamily.reap(now:, batch_size: 2)
    assert_equal 1, families.count { |family| RefreshTokenFamily.exists?(family.id) }
    assert_equal 1, RefreshTokenFamily.reap(now:, batch_size: 2)
    assert_equal 0, RefreshTokenFamily.reap(now:, batch_size: 2)
    assert families.none? { |family| RefreshTokenFamily.exists?(family.id) }
  end

  test "executor convergence ignores Agent lifecycle and reaps one bounded batch per invocation" do
    member = create_agent_member(
      display_name: "Executor cleanup",
      agent_identifier: "install-executor-cleanup"
    )
    # Distinct runner identities belong to a human, so a batch of them also
    # proves convergence ignores the Agent lifecycle entirely.
    executors = 3.times.map do |index|
      member.account.task_executors.create!(
        executor_kind: :runner,
        display_name: "Runner #{index}",
        runner_identifier: "cleanup-install-#{index}",
        manager: users(:owner),
        assignment_scope: :user_private
      )
    end
    member.remove

    assert_equal 0, TaskExecutor.converge(batch_size: 10_000)[:converged]
    assert executors.all? { |executor| executor.reload.active? }
    assert executors.all? { |executor| executor.transport_authorized_at?(1) }

    executors.each(&:revoke)
    # Reap owns the slots the shutdown window leaves: with batch 2 that is
    # one deletion per bounded invocation, so the backlog drains one row per
    # call and each call stays within its budget.
    reaped = []
    10.times do
      result = TaskExecutor.converge(batch_size: 2)
      assert_operator result[:scanned], :<=, 2
      reaped << result[:reaped]
      break if TaskExecutor.where(id: executors.map(&:id)).none?
    end
    assert_equal [1, 1, 1], reaped
    assert_equal 0, TaskExecutor.where(id: executors.map(&:id)).count
    assert_equal 0, TaskExecutor.converge(batch_size: 10_000)[:converged]

    free = @member.account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Free runner",
      runner_identifier: "free-install",
      manager: users(:owner),
      assignment_scope: :user_private
    )
    # The retained case must carry a credential, so it uses the Agent
    # Profile's own delivery address; a runner's transport credential has no
    # owning member and arrives with the runner connection.
    retained_agent = create_agent_member(
      display_name: "Retained agent",
      agent_identifier: "install-retained-agent"
    )
    blocked = retained_agent.task_executors.create!(
      account: retained_agent.account,
      executor_kind: :agent_application,
      display_name: "Retained app"
    )
    retained_family = build_family(
      user: retained_agent,
      task_executor: blocked,
      last_used_at: reapable_lapse(Time.current) - 1.minute
    )
    free.revoke
    blocked.revoke

    assert_equal 1, TaskExecutor.reap(batch_size: 10)
    assert_not TaskExecutor.exists?(free.id)
    assert TaskExecutor.exists?(blocked.id), "one retained dependency does not block another candidate"

    assert_equal 1, RefreshTokenFamily.reap(batch_size: 10)
    assert_not RefreshTokenFamily.exists?(retained_family.id)
    assert_equal 1, TaskExecutor.reap(batch_size: 10)
    assert_not TaskExecutor.exists?(blocked.id)
  end

  test "credential reapers release terminal device audit references independently" do
    now = Time.current
    family = build_family(last_used_at: reapable_lapse(now) - 1.minute)
    access = build_access(
      family:,
      expires_at: now - AccessToken::REAP_RETENTION - 1.minute
    )
    refresh = build_refresh(family:, access:)
    authorization = DeviceAuthorizations::Issue.call(
      account: @member.account,
      agent_identifier: "install-audit-reference",
      agent_display_name: "Audit reference",
      requested_executor_display_name: "Audit executor",
    ).authorization
    authorization.update_columns(
      status: "consumed",
      user_id: @member.id,
      task_executor_id: @executor.id,
      user_authority_generation: @member.authority_generation,
      access_token_id: access.id,
      refresh_token_id: refresh.id,
      updated_at: now - DeviceAuthorization::TERMINAL_RETENTION - 1.minute
    )
    @executor.revoke

    assert_equal 0, RefreshTokenFamily.reap(now:, batch_size: 2)
    assert_equal 1, RefreshToken.reap(now:, batch_size: 2)[:reaped]
    assert_nil authorization.reload.refresh_token_id
    assert_equal access.id, authorization.access_token_id

    assert_equal 1, AccessToken.reap(now:, batch_size: 2)
    assert_nil authorization.reload.access_token_id
    assert_equal 1, RefreshTokenFamily.reap(now:, batch_size: 2)

    assert_equal 0, TaskExecutor.reap(batch_size: 2),
      "the retained executor selection remains a durable dependency"
    device_reap = DeviceAuthorization.reap(now:, batch_size: 2)
    assert_equal 1, device_reap[:deleted]
    assert_equal 1, device_reap[:scanned]
    assert_equal 1, TaskExecutor.reap(batch_size: 2)
    assert_not TaskExecutor.exists?(@executor.id)
  end

  test "cleanup cannot translate Agent removal into executor revocation" do
    member = create_agent_member(
      display_name: "Re-established",
      agent_identifier: "install-re-established"
    )
    executor = member.task_executors.create!(
      account: member.account,
      executor_kind: :agent_application,
      display_name: "Re-established app"
    )
    member.remove

    assert_equal 0, TaskExecutor.converge(batch_size: 10_000)[:converged]
    assert_predicate executor.reload, :active?
    assert_not executor.transport_authorized_at?(1)
  end

  # An Agent is single-instance, so its address is durable the way a runner's machine is: a person
  # who stops using rho for a month and comes back re-pairs the address they had, instead of being
  # handed a new identity because a credential expired while they were away. Convergence
  # deliberately has no rule that ends an address on lapse — only an explicit revoke does.
  test "an address outlives a lapsed lineage, exactly as a runner's machine does" do
    build_family(last_used_at: (RefreshTokenFamily::INACTIVITY_WINDOW + 1.minute).ago)
    runner = @member.account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Lapsed runner",
      runner_identifier: "lapsed-install",
      manager: users(:owner),
      assignment_scope: :user_private
    )
    RefreshTokenFamily.create!(
      account: @member.account,
      access_token_name: "Lapsed runner lineage",
      task_executor: runner,
      credential_epoch: runner.credential_epoch,
      last_used_at: (RefreshTokenFamily::INACTIVITY_WINDOW + 1.minute).ago
    )

    assert_equal 0, TaskExecutor.converge(batch_size: 10_000)[:converged]
    assert_predicate @executor.reload, :active?
    assert_predicate runner.reload, :active?
  end

  test "the recurring schedule covers every convergence owner" do
    production = recurring_schedule
    owners = production.values.map { |entry| entry["command"] || entry["class"] }

    assert_includes owners, "DeviceAuthorizations::ReapJob"
    assert_includes owners, "RefreshTokenFamilies::ConvergeJob"
    assert_includes owners, "AccessTokens::ConvergeJob"
    assert_includes owners, "RefreshTokens::ConvergeJob"
    assert_includes owners, "Users::ConvergeJob"
    assert_includes owners, "TaskExecutors::ConvergeJob"
    assert_equal "0,30 * * * *", production.dig("converge_refresh_token_families", "schedule")
    assert_equal "5,35 * * * *", production.dig("converge_access_tokens", "schedule")
    assert_equal "10,40 * * * *", production.dig("converge_refresh_tokens", "schedule")
    assert_equal "12,42 * * * *", production.dig("converge_users", "schedule")
    assert_equal "15,45 * * * *", production.dig("converge_task_executors", "schedule")
    assert_equal "20,50 * * * *", production.dig("reap_expired_device_authorizations", "schedule")
  end

  private

    # The continuation loop each converge job drives: repeat the bounded call,
    # threading the walk's cursor, until a pass reports no more work. Returns
    # the total marked across the chain and flunks if it never terminates.
    def drain_converge(batch_size:, cursor: 0, limit: 100)
      marked = 0
      limit.times do
        result = yield cursor
        assert_operator result[:scanned], :<=, batch_size,
          "one invocation must never scan beyond its batch"
        marked += result[:marked]
        cursor = result.cursor
        return marked unless result.more?
      end
      flunk "the converge continuation chain did not terminate"
    end

    # A family is reapable once it lapsed for inactivity AND its replay evidence
    # is no longer needed — the retention ladder now hangs off the lapse,
    # because nothing expires a lineage on a calendar any more.
    def reapable_lapse(now)
      now - RefreshTokenFamily::INACTIVITY_WINDOW - RefreshToken::POST_LAPSE_RETENTION
    end

    # Every lineage is executor-bound. These tests are about MEMBER authority, which still governs
    # the bundle's member credential — that token stays unbound even though its lineage never is.
    def address_for(member)
      member.task_executors.create!(
        account: member.account, executor_kind: :agent_application, display_name: "Address"
      )
    end

    def build_family(user: @member, task_executor: @executor, last_used_at: Time.current)
      RefreshTokenFamily.create!(
        account: user.account,
        user: user,
        access_token_name: "Device connection",
        task_executor: task_executor,
        credential_epoch: task_executor&.credential_epoch,
        user_authority_generation: user.authority_generation,
        last_used_at: last_used_at
      )
    end

    # A connection's bundle carries both halves under one lineage, and they read different
    # authorities: the member credential is unbound and governed by member/steward standing, the
    # transport credential is bound and governed by the address. Every family is executor-bound now,
    # so the plane can no longer be inferred from the family — naming it is what keeps these tests
    # pointed at the authority they mean.
    def build_access(family:, plane: :member, expires_at: AccessToken::OAUTH_TTL.from_now)
      parts = AccessToken::DIGESTED.mint_parts
      bound = plane == :executor_transport
      family.user.access_tokens.create!(
        credential_plane: plane,
        refresh_token_family: family,
        name: family.access_token_name,
        source: :oauth_device,
        lookup_id: parts.lookup_id,
        secret_digest: parts.digest,
        expires_at: expires_at,
        task_executor: (family.task_executor if bound),
        credential_epoch: (family.credential_epoch if bound),
        user_authority_generation: family.user_authority_generation
      )
    end

    def build_refresh(family:, access:, consumed_at: nil, revoked_at: nil)
      parts = RefreshToken::DIGESTED.mint_parts
      family.refresh_tokens.create!(
        account: family.account,
        user: family.user,
        access_token: access,
        lookup_id: parts.lookup_id,
        secret_digest: parts.digest,
        consumed_at: consumed_at,
        revoked_at: revoked_at
      )
    end
end
