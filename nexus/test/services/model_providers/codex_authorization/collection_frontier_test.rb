require "test_helper"

class ModelProviders::CodexAuthorization::CollectionFrontierTest < ActiveJob::TestCase
  AUTH = ModelProviders::CodexAuthorization
  SWEEPS = AUTH::Sweeps

  setup do
    @account = accounts(:cybros)
    @now = Time.current.change(usec: 0)
    @before = @now - 30.days
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    )
  end

  test "finished polls do not duplicate parents or consume other sessions collection budget" do
    first = ended_device_session(ended_at: @now - 40.days, polls: 3)
    second = ended_device_session(ended_at: @now - 39.days, polls: 1)
    assert_equal 4, first.oauth_tasks.count
    assert_equal 2, second.oauth_tasks.count

    result = SWEEPS.collect_terminal_sessions(before: @before, limit: 2)

    assert_equal [2, 2, true], [result[:scanned], result[:collected], result.more?],
      "the batch counts sessions, not completed HTTP requests within one session"
    assert_equal [second.updated_at.iso8601(6), second.id], result.cursor
  end

  test "one collection pass removes its distinct parent budget and all their finished polls" do
    first = ended_device_session(ended_at: @now - 40.days, polls: 3)
    second = ended_device_session(ended_at: @now - 39.days, polls: 1)
    retained = ended_device_session(ended_at: @now - 38.days, polls: 1)

    SWEEPS.collect_terminal_sessions(before: @before, limit: 2)

    assert_empty ModelProviderOAuthSession.where(id: [first.id, second.id]).pluck(:id),
      "duplicate instances of the first parent must not displace the second parent"
    assert_empty ModelProviderOAuthTask.where(
      model_provider_oauth_session_id: [first.id, second.id]
    ).pluck(:id)
    assert ModelProviderOAuthSession.exists?(retained.id), "the third parent is a later batch"
    assert_equal 2, retained.oauth_tasks.count
  end

  test "the terminal source window is bounded before dispatching children are filtered" do
    ended_at = @now - 40.days
    retained = 2.times.map { ended_device_session(ended_at: ended_at, dispatching: true) }
    ready = ended_device_session(ended_at: ended_at + 1.second, polls: 1)

    first = SWEEPS.collect_terminal_sessions(before: @before, limit: 2)

    assert_equal [2, 0, true], [first[:scanned], first[:collected], first.more?]
    assert_equal [ended_at.iso8601(6), retained.last.id], first.cursor
    assert_equal retained.map(&:id),
      ModelProviderOAuthSession.where(id: retained.map(&:id)).order(:id).pluck(:id)
    assert_equal 2, ModelProviderOAuthTask.dispatching.count
    assert ModelProviderOAuthSession.exists?(ready.id),
      "retained source parents consume this hop's budget; the next hop reaches the ready parent"

    second = SWEEPS.collect_terminal_sessions(before: @before, limit: 2,
      after_updated_at: first.cursor.first, after_id: first.cursor.last)

    assert_equal [1, 1, false], [second[:scanned], second[:collected], second.more?]
    assert_not ModelProviderOAuthSession.exists?(ready.id)
    assert_equal 2, ModelProviderOAuthTask.dispatching.count

    retained.each do |session|
      session.oauth_tasks.sole.settle(
        state: ModelProviderOAuthTask::SPENT, normalized_status: "dispatch_deadline_exceeded",
        result_kind: "no_response", now: @now
      )
    end
    recurring = SWEEPS.collect_terminal_sessions(before: @before, limit: 2)
    assert_equal [2, 2, true], [recurring[:scanned], recurring[:collected], recurring.more?],
      "the next recurring pass revisits retained parents after their requests settle"
  end

  test "the exact terminal source stops on an indexed window above recent retained history" do
    seed_terminal_history(8_000, ended_at: @now - 1.day, dispatching: true)
    seed_terminal_history(2_001, ended_at: @now - 40.days)
    ApplicationRecord.lease_connection.execute("ANALYZE model_provider_oauth_sessions, model_provider_oauth_tasks")

    cursor = [nil, 0]
    2.times do
      result = nil
      queries = collection_queries do
        ApplicationRecord.transaction(requires_new: true) do
          result = SWEEPS.collect_terminal_sessions(before: @before, limit: 100,
            after_updated_at: cursor.first, after_id: cursor.last)
          raise ActiveRecord::Rollback
        end
      end
      assert_equal [100, 100, true], [result[:scanned], result[:collected], result.more?]
      assert_equal 1, queries.fetch(:source).length
      source_plan = explain(queries.fetch(:source).sole)
      assert_match(/\ALimit\s/, source_plan)
      assert_match(/Index (?:Only )?Scan using index_authorization_sessions_retention/, source_plan)
      assert_no_match(/Join|SubPlan|Seq Scan|Bitmap|Sort|Rows Removed by Filter: [1-9]/, source_plan)
      assert_match(/actual [^\n]*rows=100(?:\.0+)? loops=1/, source_plan)

      assert_equal 1, queries.fetch(:children).length
      child_plan = explain(queries.fetch(:children).sole)
      assert_no_match(/Seq Scan/, child_plan,
        "the child check must remain inside the selected parent IDs:\n#{child_plan}")
      assert_match(/index_authorization_tasks_by_session/, child_plan)
      assert_operator child_plan.scan(/Rows Removed by Filter: (\d+)/).flatten.sum(&:to_i), :<=, 100,
        "checking one request per selected parent must not inspect unrelated retained requests"

      deletion_plan = explain(queries.fetch(:delete_tasks).first)
      assert_match(/index_authorization_tasks_by_session/, deletion_plan)
      assert_no_match(/Seq Scan|Rows Removed by Filter: [1-9]/, deletion_plan)
      cursor = result.cursor
    end
  end

  test "a cursor preserves subsecond timestamps and advances ties in a non UTC application zone" do
    ended_at = (@now - 40.days).change(usec: 123_456)
    retained = ended_device_session(ended_at: ended_at, dispatching: true)
    same_time = ended_device_session(ended_at: ended_at, polls: 1)
    next_microsecond = ended_device_session(ended_at: ended_at + Rational(1, 1_000_000), polls: 1)

    Time.use_zone("Asia/Shanghai") do
      first = SWEEPS.collect_terminal_sessions(before: @before, limit: 1)
      assert_equal [ended_at, retained.id], [Time.iso8601(first.cursor.first), first.cursor.last]
      assert_equal [1, 0, true], [first[:scanned], first[:collected], first.more?]

      second = SWEEPS.collect_terminal_sessions(before: @before, limit: 1,
        after_updated_at: first.cursor.first, after_id: first.cursor.last)
      assert_equal [ended_at, same_time.id], [Time.iso8601(second.cursor.first), second.cursor.last]
      assert_not ModelProviderOAuthSession.exists?(same_time.id)

      third = SWEEPS.collect_terminal_sessions(before: @before, limit: 1,
        after_updated_at: second.cursor.first, after_id: second.cursor.last)
      assert_equal [ended_at + Rational(1, 1_000_000), next_microsecond.id],
        [Time.iso8601(third.cursor.first), third.cursor.last]
      assert_not ModelProviderOAuthSession.exists?(next_microsecond.id)

      empty = SWEEPS.collect_terminal_sessions(before: @before, limit: 1,
        after_updated_at: third.cursor.first, after_id: third.cursor.last)
      assert_equal [0, 0, false], [empty[:scanned], empty[:collected], empty.more?]
      assert_equal third.cursor, empty.cursor
    end
  end

  test "another collection can remove the selected parents before their deletion without stranding the pass" do
    sessions = 2.times.map { |index| ended_device_session(ended_at: @now - (40 - index).days, polls: 1) }
    other_result = nil
    duplicate_ran = false
    subscriber = lambda do |*, payload|
      next if duplicate_ran || !payload[:sql].start_with?('SELECT "model_provider_oauth_sessions".*')

      duplicate_ran = true
      other_result = SWEEPS.collect_terminal_sessions(before: @before, limit: 2)
    end
    result = nil
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      result = SWEEPS.collect_terminal_sessions(before: @before, limit: 2)
    end

    assert duplicate_ran
    assert_equal 2, other_result[:collected]
    assert_equal 2, result[:scanned]
    assert_equal [sessions.last.updated_at.iso8601(6), sessions.last.id], result.cursor
    assert_empty ModelProviderOAuthSession.where(id: sessions.map(&:id)).pluck(:id)
    assert_empty ModelProviderOAuthTask.where(model_provider_oauth_session_id: sessions.map(&:id)).pluck(:id)
  end

  test "the job carries its cutoff and collection cursor and repeated continuation skips the clock sweeps" do
    sessions = 3.times.map { |index| ended_device_session(ended_at: @now - (40 - index).days, polls: 1) }
    first_cursor = [sessions.second.updated_at.iso8601(6), sessions.second.id]
    continuation = { limit: 2, now: @now, after_updated_at: first_cursor.first, after_id: first_cursor.last }
    seal = SWEEPS.method(:seal_stale_dispatches)
    expire = SWEEPS.method(:expire_closed_windows)
    clock_calls = []
    seal_spy = ->(**args) { clock_calls << :seal; seal.call(**args) }
    expire_spy = ->(**args) { clock_calls << :expire; expire.call(**args) }

    SWEEPS.stub(:seal_stale_dispatches, seal_spy) do
      SWEEPS.stub(:expire_closed_windows, expire_spy) do
        assert_enqueued_with(job: ModelProviderOAuthSessions::SweepJob, args: [{ limit: 2, now: @now,
          after_updated_at: first_cursor.first, after_id: first_cursor.last }]) do
          ModelProviderOAuthSessions::SweepJob.perform_now(limit: 2, now: @now)
        end
        assert_equal %i[seal expire], clock_calls
        assert ModelProviderOAuthSession.exists?(sessions.third.id)

        clear_enqueued_jobs
        assert_no_enqueued_jobs(only: ModelProviderOAuthSessions::SweepJob) do
          ModelProviderOAuthSessions::SweepJob.perform_now(**continuation)
          ModelProviderOAuthSessions::SweepJob.perform_now(**continuation)
        end
        assert_equal %i[seal expire], clock_calls
        assert_empty ModelProviderOAuthSession.where(id: sessions.map(&:id)).pluck(:id)
      end
    end
  end

  private

    def ended_device_session(ended_at:, polls: 0, dispatching: false)
      started_at = ended_at - 2.minutes
      travel_to(started_at) do
        session = AUTH::AcceptSession.call(
          account: @account, issuing_user: users(:owner), kind: "device_start"
        ).session
        task = AUTH::Claim.call(session: session).task
        unless dispatching
          AUTH::ApplyDeviceStart.call(
            session: session, task: task, normalized_status: "http_200",
            outcome: AUTH::Responses.user_code(
              status: 200,
              body: { "device_auth_id" => "device", "user_code" => "R20K-H1Q40", "interval" => "5" }.to_json
            )
          )
          polls.times do |index|
            now = started_at + (index + 1) * 5.seconds
            task = AUTH::Claim.call(session: session.reload, now: now).task
            AUTH::ApplyDeviceStart.call(
              session: session, task: task, normalized_status: "http_403", now: now,
              outcome: AUTH::Responses.device_token_poll(
                status: 403, body: { "error" => { "code" => "deviceauth_authorization_pending" } }.to_json
              )
            )
          end
        end
        AUTH::ClearAuthorization.call(account: @account, now: ended_at)
        session.reload
      end
    end

    def seed_terminal_history(count, ended_at:, dispatching: false)
      ids = ModelProviderOAuthSession.insert_all!(Array.new(count) do
        { account_id: @account.id, issuing_user_id: users(:owner).id,
          provider_id: "codex_subscription", kind: "device_start", state: "revoked",
          progress: "accepted", semantic_exchange_kind: "user_code_request",
          semantic_exchange_ordinal: 0, authorization_lineage_id: SecureRandom.uuid,
          outcome: "operator_revoked", sanitized_reason: "operator_revoked",
          created_at: ended_at - 2.minutes, updated_at: ended_at }
      end, returning: %w[id]).rows.flatten
      ModelProviderOAuthTask.insert_all!(ids.map do |id|
        { account_id: @account.id, model_provider_oauth_session_id: id,
          exchange_kind: "user_code_request", state: dispatching ? "dispatching" : "spent",
          claimed_at: ended_at - 2.minutes, deadline_at: ended_at + 13.minutes,
          settled_at: dispatching ? nil : ended_at,
          normalized_status: dispatching ? nil : "Errno::ECONNREFUSED",
          result_kind: dispatching ? nil : "no_response", created_at: ended_at - 2.minutes, updated_at: ended_at }
      end)
    end

    def collection_queries
      queries = { source: [], children: [], delete_tasks: [] }
      subscriber = lambda do |*, payload|
        next if payload[:cached]

        sql = payload[:sql]
        kind = if sql.start_with?('SELECT "model_provider_oauth_sessions"."id", "model_provider_oauth_sessions"."updated_at"')
          :source
        elsif sql.start_with?('SELECT "model_provider_oauth_sessions".*')
          :children
        elsif sql.start_with?('DELETE FROM "model_provider_oauth_tasks"')
          :delete_tasks
        end
        queries.fetch(kind) << [sql.dup, payload.fetch(:binds).dup] if kind
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      queries
    end

    def explain(query)
      sql, binds = query
      plan = nil
      ApplicationRecord.transaction(requires_new: true) do
        plan = ApplicationRecord.lease_connection.select_values(
          "EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds
        ).join("\n")
        raise ActiveRecord::Rollback
      end
      plan
    end
end
