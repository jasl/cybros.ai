require "test_helper"

# M7's bounded-source contract, pinned (plan: no recurring invocation may
# prove an empty result only by scanning its complete retained corpus).
# These pins guard the SHAPES that make each sweep bounded — index-aligned
# phases instead of multi-cause ORs, source windows before unindexable
# predicates, materialized ids before the applying statement — because each
# was originally written the other way and measured unbounded.
class BoundedSourceSweepsTest < ActiveSupport::TestCase
  test "session expiry discovery enters its composite index at scale" do
    identity = identities(:member)
    now = Time.current
    Session.insert_all!(
      Array.new(4_000) do |index|
        {
          account_id: identity.user.account_id,
          identity_id: identity.id,
          user_id: identity.user.id,
          expires_at: now + (index + 1).minutes,
          user_authority_generation: identity.user.authority_generation,
          identity_recovery_generation: identity.credential_recovery_generation,
          created_at: now, updated_at: now,
        }
      end
    )
    ApplicationRecord.lease_connection.execute("ANALYZE sessions")

    captured = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "sessions"."id"') && sql.include?("expires_at")
        captured ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      result = Session.reap(now: now, batch_size: 100)
      assert_equal 0, result[:expired], "every seeded session is live — this is the idle pass"
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert captured, "the reaper must run its bounded expiry source scan"
    sql, binds = captured
    plan = ApplicationRecord.lease_connection
      .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    assert_match(/index_sessions_on_expires_at_and_id/, plan)
    assert_no_match(/Seq Scan on sessions(?:\s|$)/, plan,
      "an idle pass proves emptiness from the index, never from the corpus")
  end

  # The old single OR DELETE could satisfy no index; each cause now walks its
  # own partial index. Keep terminal evidence dense and current evidence rare
  # so dropping any one of the three source indexes makes its idle proof read
  # the retained corpus instead.
  test "recovery evidence reaping is three index-aligned phases, never one OR" do
    identity = identities(:member)
    now = Time.current
    prefix = SecureRandom.hex(4)
    common = {
      account_id: identity.user.account_id,
      identity_id: identity.id,
      user_id: identity.user.id,
      generation: identity.credential_recovery_generation,
      secret_digest: "bounded-source-plan",
      expires_at: now + 1.day,
      created_at: now,
      updated_at: now,
    }
    # At a few thousand compact rows PostgreSQL can rationally prefer a table
    # scan, so that shape does not prove the retained-history frontier. Make
    # the inactive history large enough that crossing it is material even on
    # a freshly prepared, unbloated test database.
    rows = Array.new(20_000) do |index|
      common.merge(
        lookup_id: "#{prefix}-c-#{index}",
        consumed_at: now - 1.day,
        superseded_at: nil
      )
    end
    rows.concat(Array.new(2_000) do |index|
      common.merge(
        lookup_id: "#{prefix}-s-#{index}",
        consumed_at: nil,
        superseded_at: now - 1.day
      )
    end)
    rows.concat([
      common.merge(
        lookup_id: "#{prefix}-c-due",
        consumed_at: now - 31.days,
        superseded_at: nil
      ),
      common.merge(
        lookup_id: "#{prefix}-s-due",
        consumed_at: nil,
        superseded_at: now - 31.days
      ),
      common.merge(
        lookup_id: "#{prefix}-e-due",
        expires_at: now - 31.days,
        consumed_at: nil,
        superseded_at: nil
      ),
    ])
    rows.each_slice(1_000) { |slice| MemberRecoveryAuthorization.insert_all!(slice) }
    ApplicationRecord.lease_connection.execute(
      "ANALYZE member_recovery_authorizations"
    )

    selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "member_recovery_authorizations"."id"')
        selects << [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      result = MemberRecoveryAuthorization.reap(now: now, batch_size: 30)
      assert_equal 3, result[:scanned]
      assert_equal 3, result[:reaped]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 3, selects.length, "one bounded discovery per cause"
    assert selects.none? { |sql,| sql.include?(" OR ") },
      "a multi-cause OR is the shape that can satisfy no index"
    expected_indexes = {
      "consumed_at" =>
        "index_member_recovery_authorizations_on_consumed_evidence",
      "superseded_at" =>
        "index_member_recovery_authorizations_on_superseded_evidence",
      "expires_at" =>
        "index_member_recovery_authorizations_on_unconsumed_expiry",
    }
    expected_indexes.each do |column, index_name|
      statement = selects.find { |sql,| sql.include?("#{column}\" <=") }
      assert statement, "the #{column} phase must execute its production source query"

      plan = explain(*statement)
      assert_match(/#{Regexp.escape(index_name)}/, plan)
      assert_no_match(/Seq Scan on member_recovery_authorizations(?:\s|$)/, plan)
    end
  end

  test "agent-profile discovery enters its partial source index at scale" do
    account = accounts(:cybros)
    steward = users(:owner)
    now = Time.current
    prefix = SecureRandom.hex(4)
    identity_ids = Identity.insert_all!(
      Array.new(2_000) do |index|
        {
          account_id: account.id,
          email: "bounded-#{prefix}-#{index}@example.test",
          password_digest: identities(:owner).password_digest,
          created_at: now,
          updated_at: now,
        }
      end,
      returning: %w[id]
    ).rows.flatten
    human_rows = identity_ids.map.with_index do |identity_id, index|
      {
        account_id: account.id,
        identity_id: identity_id,
        display_name: "Retained human #{index}",
        handle: "retained-human-#{index}",
        kind: "human",
        role: "member",
        status: "active",
        steward_id: nil,
        agent_identifier: nil,
        applied_steward_shutdown_generation: 0,
        created_at: now,
        updated_at: now,
      }
    end
    agent_rows = Array.new(100) do |index|
      {
        account_id: account.id,
        identity_id: nil,
        display_name: "Active agent #{index}",
        handle: "bounded-agent-#{prefix}-#{index}",
        kind: "agent",
        role: "member",
        status: "active",
        steward_id: steward.id,
        agent_identifier: "bounded-agent-#{prefix}-#{index}",
        applied_steward_shutdown_generation:
          steward.managed_resource_shutdown_generation,
        created_at: now,
        updated_at: now,
      }
    end
    (human_rows + agent_rows).each_slice(1_000) { |slice| User.insert_all!(slice) }
    ApplicationRecord.lease_connection.execute("ANALYZE users")

    captured = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "users"."id" FROM "users"') &&
          sql.include?('ORDER BY "users"."id" ASC')
        captured ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      result = User.converge(batch_size: 50, after_id: 0)
      assert_equal 50, result[:scanned]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert captured, "convergence must execute its bounded Agent source window"
    plan = explain(*captured)
    assert_match(/index_users_on_agent_window/, plan)
    assert_no_match(/Seq Scan on users(?:\s|$)/, plan)
  end

  test "active executor discovery enters its partial source index at scale" do
    account = accounts(:cybros)
    manager = users(:owner)
    now = Time.current
    prefix = SecureRandom.hex(4)
    # 20k retained rows make the plan choice decisive in EVERY environment:
    # on a freshly built CI database relallvisible is 0, so the planner costs
    # the partial-index path as a full heap re-fetch — at 2k rows that lost
    # to a Seq Scan + Sort by a knife edge (CI-red/local-green), at 20k the
    # index wins under either visibility assumption.
    rows = Array.new(20_000) do |index|
      {
        account_id: account.id,
        manager_id: manager.id,
        executor_kind: "runner",
        display_name: "Retained executor #{index}",
        registration_identifier: "bounded-revoked-#{prefix}-#{index}",
        assignment_scope: "user_private",
        status: "revoked",
        applied_human_shutdown_generation:
          manager.managed_resource_shutdown_generation,
        created_at: now,
        updated_at: now,
      }
    end
    rows.concat(Array.new(100) do |index|
      {
        account_id: account.id,
        manager_id: manager.id,
        executor_kind: "runner",
        display_name: "Active executor #{index}",
        registration_identifier: "bounded-active-#{prefix}-#{index}",
        assignment_scope: "user_private",
        status: "active",
        applied_human_shutdown_generation:
          manager.managed_resource_shutdown_generation,
        created_at: now,
        updated_at: now,
      }
    end)
    rows.each_slice(1_000) { |slice| TaskExecutor.insert_all!(slice) }
    ApplicationRecord.lease_connection.execute("ANALYZE task_executors")

    captured = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "task_executors"."id" FROM "task_executors"') &&
          sql.include?("task_executors.status = 'active'")
        captured ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      result = TaskExecutor.converge(
        batch_size: 100, shutdown_after_id: 0, reap_after_id: nil
      )
      assert_equal 50, result[:scanned]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert captured, "convergence must execute its bounded active source window"
    plan = explain(*captured)
    assert_match(/index_task_executors_on_active_id/, plan)
    assert_no_match(/Seq Scan on task_executors(?:\s|$)/, plan)
  end

  test "refresh-token evidence reaping is index-aligned phases with a family-side lapse window" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      statements << sql if sql.match?(/\ASELECT/)
    end
    begin
      RefreshToken.reap(batch_size: 30)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    token_scans = statements.select { |sql| sql.include?('FROM "refresh_tokens"') }
    assert token_scans.none? { |sql| sql.include?(" OR ") },
      "the three-arm OR read the whole token corpus to prove an idle pass empty"
    assert_equal 1, statements.count { |sql|
      sql.include?('FROM "refresh_token_families"') && sql.include?("last_used_at")
    }, "the lapsed arm walks families — the side that outlives its tokens and carries the cursor"
  end

  # Marker discovery takes its source window bare and applies the fence to
  # the materialized ids: the window statement itself must carry no join.
  test "fenced-marker discovery windows are bare primary-key walks" do
    windows = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.match?(/\ASELECT.*"id" FROM "(refresh_token_families|access_tokens)"/) &&
          sql.match?(/"id" >/)
        windows << sql
      end
    end
    begin
      RefreshTokenFamily.mark_permanently_fenced(batch_size: 10)
      AccessToken.mark_permanently_fenced(batch_size: 10)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 2, windows.length, "each marker must run exactly one source window"
    assert windows.none? { |sql| sql.include?("JOIN") },
      "the fence join belongs to the second statement, over the materialized window ids"
  end

  private

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end
end
