require "test_helper"

# The credential sweeps have two separate boundedness obligations: each
# retention cause must enter its own ordered index, and every predicate that
# crosses an authority owner must run only after a bare source window has
# consumed scan budget. These tests use the production relations themselves.
class TokenConvergenceSourceBoundsTest < ActiveJob::TestCase
  include ActiveSupport::Testing::ConstantStubbing

  test "access-token reap splits causes without exceeding or double-spending its budget" do
    now = Time.current
    revoked = insert_access_tokens(1, expires_at: now + 1.day, revoked_at: 31.days.ago).sole
    both = insert_access_tokens(1, expires_at: 31.days.ago, revoked_at: 31.days.ago).sole
    expired = insert_access_tokens(1, expires_at: 31.days.ago, revoked_at: nil).sole

    assert_equal 2, AccessToken.reap(now:, batch_size: 2)
    assert_not AccessToken.exists?(revoked)
    assert_not AccessToken.exists?(both)
    assert AccessToken.exists?(expired),
      "a row matching both causes consumes the shared budget only once"

    assert_equal 1, AccessToken.reap(now:, batch_size: 2)
    assert_not AccessToken.exists?(expired)
    assert_equal 0, AccessToken.reap(now:, batch_size: 2)
  end

  test "access-token reap runs two exact index-aligned production discoveries" do
    now = Time.current
    insert_access_tokens(4_000, expires_at: now + 1.day, revoked_at: nil)
    insert_access_tokens(20, expires_at: now + 1.day, revoked_at: 31.days.ago)
    insert_access_tokens(20, expires_at: 31.days.ago, revoked_at: nil)
    analyze("access_tokens")

    statements = capture_sql do
      AccessToken.transaction(requires_new: true) do
        AccessToken.reap(now:, batch_size: 30)
        raise ActiveRecord::Rollback
      end
    end.select { |sql, _binds| access_token_discovery?(sql) }

    assert_equal 2, statements.length
    assert statements.none? { |sql, _binds| sql.include?(" OR ") }

    revoked_plan = explain_analyze(statement_for(statements, "revoked_at"))
    expired_plan = explain_analyze(statement_for(statements, "expires_at"))
    assert_match(/index_access_tokens_on_revoked_at_and_id/, revoked_plan)
    assert_match(/index_access_tokens_on_expires_at_and_id/, expired_plan)
    assert_no_match(/Seq Scan on access_tokens(?:\s|$)/, revoked_plan)
    assert_no_match(/Seq Scan on access_tokens(?:\s|$)/, expired_plan)
  end

  test "access-token source rows spend budget even when the applying delete loses" do
    now = Time.current
    insert_access_tokens(2, expires_at: now + 1.day, revoked_at: 31.days.ago)
    insert_access_tokens(2, expires_at: 31.days.ago, revoked_at: nil)

    statements = capture_sql do
      AccessToken.stub(:delete_reap_window, ->(_window) { 0 }) do
        @access_reap = AccessToken.send(:reap_batch, now:, batch_size: 2)
      end
    end

    assert_equal 0, @access_reap[:reaped]
    assert_equal 2, @access_reap[:scanned]
    assert @access_reap.more?
    discoveries = statements.select { |sql, _binds| access_token_discovery?(sql) }
    assert_equal 1, discoveries.count { |sql, _binds| sql.include?('"revoked_at" <=') }
    assert_equal 0, discoveries.count { |sql, _binds| sql.include?('"expires_at" <=') },
      "a full materialized revoked window leaves no budget for the next cause"
  end

  test "access marker parks after a partial window and a fresh pass revisits later rows" do
    now = Time.current
    stale = insert_access_tokens(
      4,
      expires_at: now - AccessToken::REAP_RETENTION - 1.day,
      revoked_at: nil
    )
    marker_start = AccessToken.maximum(:id)
    first_candidate = insert_access_tokens(
      1, expires_at: now + 1.day, revoked_at: nil
    ).sole
    fence_access_tokens(first_candidate)

    first = AccessToken.where(id: stale + [first_candidate]).converge(
      now: now, batch_size: 4, marker_after_id: marker_start
    )
    assert_equal [1, 3, 4, true],
      [first[:marked], first[:reaped], first[:scanned], first.more?]
    assert_nil first.cursor,
      "a partial marker window parks even while reaping needs another hop"

    late_candidate = insert_access_tokens(
      1, expires_at: now + 1.day, revoked_at: nil
    ).sole
    fence_access_tokens(late_candidate)
    probe = AccessToken.where(id: stale + [first_candidate, late_candidate])
    continuation_sql = capture_sql do
      @parked_access_result = probe.converge(
        now: now, batch_size: 4, marker_after_id: first.cursor
      )
    end

    assert continuation_sql.none? { |sql, _binds| access_marker_window?(sql) },
      "a parked marker must not chase rows created during the continuation chain"
    assert_not AccessToken.find(late_candidate).revoked?
    assert_not @parked_access_result.more?

    fresh = probe.converge(now: now, batch_size: 10, marker_after_id: 0)
    assert_operator fresh[:marked], :>=, 1
    assert AccessToken.find(late_candidate).revoked?,
      "the next fresh recurring pass restarts the marker from zero"
  end

  test "refresh marker enters the unrevoked token index before joining family authority" do
    now = Time.current
    live_family = insert_families(1, last_used_at: now, revoked_at: nil).sole
    revoked_family = insert_families(1, last_used_at: now, revoked_at: now).sole
    insert_refresh_tokens(4_000, family_id: live_family, consumed_at: now, revoked_at: now)
    insert_refresh_tokens(4_000, family_id: live_family, consumed_at: now, revoked_at: nil)
    candidate = insert_refresh_tokens(
      1, family_id: revoked_family, consumed_at: now, revoked_at: nil
    ).sole
    analyze("refresh_tokens")
    analyze("refresh_token_families")

    statements = capture_sql do
      RefreshToken.mark_revoked_families(now:, batch_size: 100)
    end
    window = statements.find { |sql, _binds| refresh_marker_window?(sql) }

    assert window, "the marker must materialize a bare unrevoked-token window"
    assert_no_match(/JOIN/, window.first)
    plan = explain_analyze(window)
    assert_match(/index_refresh_tokens_on_unrevoked_id/, plan)
    assert_no_match(/Seq Scan on refresh_tokens(?:\s|$)/, plan)
    assert_nil RefreshToken.find(candidate).revoked_at,
      "the bounded first window does not jump across the clean source corpus"
  end

  test "refresh evidence source rows spend budget even when the applying delete loses" do
    now = Time.current
    family = insert_families(1, last_used_at: now, revoked_at: nil).sole
    insert_refresh_tokens(
      2, family_id: family, consumed_at: nil,
      revoked_at: now - RefreshToken::EVIDENCE_RETENTION - 1.day
    )
    insert_refresh_tokens(
      2, family_id: family,
      consumed_at: now - RefreshToken::EVIDENCE_RETENTION - 1.day,
      revoked_at: nil
    )

    statements = capture_sql do
      RefreshToken.stub(:delete_evidence_window, ->(_window) { 0 }) do
        @refresh_reap = RefreshToken.reap(now:, batch_size: 2)
      end
    end

    assert_equal 0, @refresh_reap[:reaped]
    assert_equal 2, @refresh_reap[:scanned]
    assert @refresh_reap.more?
    discoveries = statements.select { |sql, _binds| refresh_token_evidence_discovery?(sql) }
    assert_equal 1, discoveries.count { |sql, _binds| sql.include?('"revoked_at" <=') }
    assert_equal 0, discoveries.count { |sql, _binds| sql.include?('"consumed_at" <=') },
      "a full materialized revoked window leaves no budget for the next cause"
  end

  test "refresh convergence carries and parks its two source cursors independently" do
    now = Time.current
    lapsed_at = now - RefreshTokenFamily::INACTIVITY_WINDOW -
      RefreshToken::POST_LAPSE_RETENTION - 1.day
    insert_families(3, last_used_at: lapsed_at, revoked_at: nil)
    live_family = insert_families(1, last_used_at: now, revoked_at: nil).sole
    revoked_family = insert_families(1, last_used_at: now, revoked_at: now).sole
    clean = insert_refresh_tokens(
      5, family_id: live_family, consumed_at: now, revoked_at: nil
    )
    candidate = insert_refresh_tokens(
      1, family_id: revoked_family, consumed_at: now, revoked_at: nil
    ).sole
    marker_start = clean.first - 1

    first = RefreshToken.converge(
      now:, batch_size: 4, lapsed_after: nil, marker_after_id: marker_start
    )
    assert_equal 4, first[:scanned]
    assert_instance_of Array, first.cursor.first
    assert_equal clean.second, first.cursor.last
    assert first.more?

    second = RefreshToken.converge(
      now:, batch_size: 4,
      lapsed_after: first.cursor.first,
      marker_after_id: first.cursor.last
    )
    assert_equal false, second.cursor.first,
      "the completed lapsed walk parks instead of restarting at the top"
    assert_equal clean.fifth, second.cursor.last
    assert second.more?

    third_sql = capture_sql do
      @third = RefreshToken.converge(
        now:, batch_size: 4,
        lapsed_after: second.cursor.first,
        marker_after_id: second.cursor.last
      )
    end
    assert third_sql.none? { |sql, _binds| lapsed_family_window?(sql) },
      "a parked lapsed walk does not rescan while the marker finishes"
    assert_nil @third.cursor.last
    assert_not @third.more?
    assert_equal now.to_i, RefreshToken.find(candidate).revoked_at.to_i
  end

  test "refresh converge job preserves both active cursors" do
    now = Time.current
    lapsed_at = now - RefreshTokenFamily::INACTIVITY_WINDOW -
      RefreshToken::POST_LAPSE_RETENTION - 1.day
    lapsed = insert_families(3, last_used_at: lapsed_at, revoked_at: nil)
    live_family = insert_families(1, last_used_at: now, revoked_at: nil).sole
    clean = insert_refresh_tokens(
      3, family_id: live_family, consumed_at: now, revoked_at: nil
    )
    marker_start = clean.first - 1
    expected_lapsed = RefreshTokenFamily.where(id: lapsed)
      .order(:last_used_at, :id).second

    stub_const(RefreshTokens::ConvergeJob, :BATCH, 4) do
      assert_enqueued_with(
        job: RefreshTokens::ConvergeJob,
        args: [
          [expected_lapsed.last_used_at.iso8601(6), expected_lapsed.id],
          clean.second,
        ]
      ) do
        RefreshTokens::ConvergeJob.perform_now(nil, marker_start)
      end
    end
  end

  private

    def insert_access_tokens(count, expires_at:, revoked_at:)
      now = Time.current
      prefix = SecureRandom.hex(3)
      rows = Array.new(count) do |index|
        {
          account_id: users(:member).account_id,
          user_id: users(:member).id,
          name: "Bounded source probe",
          source: "personal",
          credential_plane: "member",
          lookup_id: "#{prefix}a#{index.to_s.rjust(16, "0")}",
          secret_digest: "probe",
          expires_at: expires_at,
          revoked_at: revoked_at,
          user_authority_generation: users(:member).authority_generation,
          created_at: now,
          updated_at: now,
        }
      end
      AccessToken.insert_all!(rows, returning: %w[id]).rows.flatten
    end

    def insert_families(count, last_used_at:, revoked_at:)
      now = Time.current
      member = create_agent_member(
        display_name: "Bounded source owner",
        agent_identifier: "bounded-#{SecureRandom.hex(6)}"
      )
      executor = member.task_executors.create!(
        account: member.account,
        executor_kind: :agent_application,
        display_name: "Bounded source executor"
      )
      base_epoch = executor.credential_epoch + SecureRandom.random_number(1_000_000) + 1
      rows = Array.new(count) do |index|
        {
          account_id: member.account_id,
          user_id: member.id,
          access_token_name: "Bounded family #{index}",
          task_executor_id: executor.id,
          credential_epoch: base_epoch + index,
          user_authority_generation: member.authority_generation,
          last_used_at: last_used_at + index,
          revoked_at: revoked_at,
          created_at: now,
          updated_at: now,
        }
      end
      RefreshTokenFamily.insert_all!(rows, returning: %w[id]).rows.flatten
    end

    def insert_refresh_tokens(count, family_id:, consumed_at:, revoked_at:)
      now = Time.current
      family = RefreshTokenFamily.find(family_id)
      prefix = SecureRandom.hex(3)
      rows = Array.new(count) do |index|
        {
          account_id: family.account_id,
          user_id: family.user_id,
          refresh_token_family_id: family.id,
          lookup_id: "#{prefix}r#{index.to_s.rjust(16, "0")}",
          secret_digest: "probe",
          consumed_at: consumed_at,
          revoked_at: revoked_at,
          created_at: now,
          updated_at: now,
        }
      end
      RefreshToken.insert_all!(rows, returning: %w[id]).rows.flatten
    end

    def analyze(table)
      ApplicationRecord.lease_connection.execute("ANALYZE #{table}")
    end

    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        if sql.match?(/\A(?:SELECT|UPDATE|DELETE)/)
          statements << [sql.dup, payload.fetch(:binds).dup]
        end
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    def access_token_discovery?(sql)
      sql.start_with?('SELECT "access_tokens"."id" FROM "access_tokens"') &&
        (sql.include?('"revoked_at" <=') || sql.include?('"expires_at" <='))
    end

    def access_marker_window?(sql)
      sql.start_with?('SELECT "access_tokens"."id" FROM "access_tokens"') &&
        sql.include?('"access_tokens"."id" >=') &&
        !sql.include?('"revoked_at" <=') &&
        !sql.include?('"expires_at" <=')
    end

    def fence_access_tokens(*ids)
      AccessToken.where(id: ids).update_all(
        user_authority_generation: users(:member).authority_generation + 1
      )
    end

    def refresh_marker_window?(sql)
      sql.start_with?('SELECT "refresh_tokens"."id" FROM "refresh_tokens"') &&
        sql.include?('"revoked_at" IS NULL') && sql.include?('"id" >=')
    end

    def refresh_token_evidence_discovery?(sql)
      sql.start_with?('SELECT "refresh_tokens"."id" FROM "refresh_tokens"') &&
        (sql.include?('"revoked_at" <=') || sql.include?('"consumed_at" <='))
    end

    def lapsed_family_window?(sql)
      sql.start_with?('SELECT "refresh_token_families"."last_used_at"') &&
        sql.include?('"refresh_token_families"."id"')
    end

    def statement_for(statements, column)
      statements.find { |sql, _binds| sql.include?(%Q("#{column}" <=)) } ||
        flunk("missing #{column} discovery")
    end

    def explain_analyze(statement)
      sql, binds = statement
      ApplicationRecord.lease_connection.select_values(
        "EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds
      ).join("\n")
    end
end
