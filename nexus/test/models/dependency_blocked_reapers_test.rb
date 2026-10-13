require "test_helper"

# A retained dependency may make every old row in a reap window ineligible.
# These regressions pin the source-first shape: blockers consume the bounded
# window and advance only this continuation chain, while the next recurring
# run starts at the beginning and can collect dependencies released later.
class DependencyBlockedReapersTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @manager = users(:owner)
    @now = Time.current.change(usec: 0)
    @lapsed_at = @now - RefreshTokenFamily::INACTIVITY_WINDOW -
      RefreshToken::POST_LAPSE_RETENTION - 1.day
  end

  test "family reap walks past a blocked window and recurring revisits it" do
    families = seed_families(count: 3, blocked: 2)

    first = RefreshTokenFamily.converge(
      now: @now, batch_size: 2, marker_after_id: nil
    )
    assert_equal [0, 2, true], [first[:reaped], first[:scanned], first.more?]
    assert first.cursor.last

    second = RefreshTokenFamily.converge(
      now: @now, batch_size: 2, marker_after_id: nil,
      reap_after: first.cursor.last
    )
    assert_equal [1, 1, false], [second[:reaped], second[:scanned], second.more?]
    assert_nil second.cursor.last
    assert_not RefreshTokenFamily.exists?(families.last.id)
    assert RefreshTokenFamily.exists?(families.first.id)

    RefreshToken.where(refresh_token_family_id: families.first.id).delete_all
    parked = RefreshTokenFamily.converge(
      now: @now, batch_size: 2, marker_after_id: nil, reap_after: nil
    )
    assert_equal [0, 0, false], [parked[:reaped], parked[:scanned], parked.more?]
    assert RefreshTokenFamily.exists?(families.first.id)

    recurring = RefreshTokenFamily.converge(
      now: @now, batch_size: 2, marker_after_id: nil
    )
    assert_equal [1, 2, true], [recurring[:reaped], recurring[:scanned], recurring.more?]
    assert_not RefreshTokenFamily.exists?(families.first.id)
    assert RefreshTokenFamily.exists?(families.second.id)
  end

  test "family reap continuation terminates linearly over an all-blocked corpus" do
    seed_families(count: 7, blocked: 7)

    cursor = RefreshTokenFamily::Convergence::REAP_CURSOR_START
    calls = 0
    scanned = 0
    loop do
      result = RefreshTokenFamily.converge(
        now: @now, batch_size: 3, marker_after_id: nil, reap_after: cursor
      )
      calls += 1
      scanned += result[:scanned]
      assert_equal 0, result[:reaped]
      assert_operator result[:scanned], :<=, 3
      cursor = result.cursor.last
      break unless result.more?
    end

    assert_equal 3, calls
    assert_equal 7, scanned
    assert_nil cursor
  end

  test "family reap parks an empty source pass" do
    result = RefreshTokenFamily.converge(
      now: @now,
      batch_size: 10,
      marker_after_id: nil,
      reap_after: [@now.iso8601(6), 0]
    )

    assert_equal [0, 0, false], [result[:reaped], result[:scanned], result.more?]
    assert_nil result.cursor.last
  end

  test "family dependency checks stay inside the indexed source window at scale" do
    seed_families(count: 4_000, blocked: 4_000)
    ApplicationRecord.lease_connection.execute(
      "ANALYZE refresh_token_families, refresh_tokens, access_tokens"
    )

    source_scan = nil
    deletion = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA" || payload[:cached]

      if sql.start_with?(
        'SELECT "refresh_token_families"."last_used_at", "refresh_token_families"."id"'
      )
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      elsif sql.start_with?('DELETE FROM "refresh_token_families"')
        deletion ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      assert_equal 0, RefreshTokenFamily.reap(now: @now, batch_size: 500)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert source_scan, "the public reaper must execute its bounded lapse source scan"
    assert deletion, "the public reaper must recheck dependencies for the materialized ids"
    source_plan = explain(*source_scan)
    deletion_plan = explain(*deletion)

    assert_match(
      /Index(?: Only)? Scan using index_refresh_token_families_on_last_used_at_and_id/,
      source_plan
    )
    assert_match(/refresh_token_families_pkey/, deletion_plan)
    assert_match(/index_refresh_tokens_on_(?:unrevoked_)?family_and_id/, deletion_plan)
    assert_no_match(/Seq Scan on refresh_token_families(?:\s|$)/, source_plan)
    assert_no_match(/Seq Scan on refresh_tokens(?:\s|$)/, deletion_plan)
    assert_no_match(/Hash (?:Right )?Anti Join/, deletion_plan)
  end

  test "executor reap walks past a blocked window and recurring revisits it" do
    executors = seed_executors(count: 3, blocked: 2)

    first = TaskExecutor.converge(
      batch_size: 2, shutdown_after_id: nil, reap_after_id: 0
    )
    assert_equal [0, 2, true], [first[:reaped], first[:scanned], first.more?]
    assert first.cursor.last

    second = TaskExecutor.converge(
      batch_size: 2, shutdown_after_id: nil,
      reap_after_id: first.cursor.last
    )
    assert_equal [1, 1, false], [second[:reaped], second[:scanned], second.more?]
    assert_nil second.cursor.last
    assert_not TaskExecutor.exists?(executors.last.id)
    assert TaskExecutor.exists?(executors.first.id)

    AccessToken.where(task_executor_id: executors.first.id).delete_all
    parked = TaskExecutor.converge(
      batch_size: 2, shutdown_after_id: nil, reap_after_id: nil
    )
    assert_equal [0, 0, false], [parked[:reaped], parked[:scanned], parked.more?]
    assert TaskExecutor.exists?(executors.first.id)

    recurring = TaskExecutor.converge(
      batch_size: 2, shutdown_after_id: nil, reap_after_id: 0
    )
    assert_equal [1, 2, true], [recurring[:reaped], recurring[:scanned], recurring.more?]
    assert_not TaskExecutor.exists?(executors.first.id)
    assert TaskExecutor.exists?(executors.second.id)
  end

  # A revoked executor is not reaped while a non-terminal row is addressed to it or claimed by it;
  # terminal history nullifies at the reap.
  test "executor reap waits on a non-terminal addressed or claimed row and nullifies terminal history" do
    @workspace = workspaces(:shared)
    @human = users(:member)
    agent_run = seed(tool("held"), tool("done"))
    held = agent_run.agent_run_tasks.find_by!(node_key: "held")
    done = agent_run.agent_run_tasks.find_by!(node_key: "done")
    addressed, claimant = seed_executors(count: 2, blocked: 0)

    held.update_columns(status: "dispatched", addressed_executor_id: addressed.id)
    done.update_columns(status: "completed", addressed_executor_id: addressed.id,
      claimed_by_executor_id: claimant.id, claimed_by_executor_public_id: claimant.public_id)
    assert_equal 1, TaskExecutor.reap(batch_size: 10), "only the claimant of settled history goes"
    assert TaskExecutor.exists?(addressed.id)
    assert_not TaskExecutor.exists?(claimant.id)
    assert_nil done.reload.claimed_by_executor_id, "the FK nullified"
    assert_equal claimant.public_id, done.claimed_by_executor_public_id, "the snapshot survives"

    held.update_columns(addressed_executor_id: nil, claimed_by_executor_id: addressed.id)
    assert_equal 0, TaskExecutor.reap(batch_size: 10), "a live claim holds the executor too"

    held.update_columns(status: "completed")
    assert_equal 1, TaskExecutor.reap(batch_size: 10)
    assert_nil held.reload.claimed_by_executor_id
    assert_nil done.reload.addressed_executor_id
  end

  test "executor reap continuation terminates linearly over an all-blocked corpus" do
    seed_executors(count: 7, blocked: 7)

    cursor = 0
    calls = 0
    scanned = 0
    loop do
      result = TaskExecutor.converge(
        batch_size: 3, shutdown_after_id: nil, reap_after_id: cursor
      )
      calls += 1
      scanned += result[:scanned]
      assert_equal 0, result[:reaped]
      assert_operator result[:scanned], :<=, 3
      cursor = result.cursor.last
      break unless result.more?
    end

    assert_equal 3, calls
    assert_equal 7, scanned
    assert_nil cursor
  end

  test "executor reap parks an empty source pass" do
    result = TaskExecutor.converge(
      batch_size: 10,
      shutdown_after_id: nil,
      reap_after_id: TaskExecutor.maximum(:id).to_i
    )

    assert_equal [0, 0, false], [result[:reaped], result[:scanned], result.more?]
    assert_nil result.cursor.last
  end

  test "executor dependency checks stay inside the indexed source window at scale" do
    seed_active_executors(count: 8_000)
    executors = seed_executors(count: 4_000, blocked: 0)
    insert_all_executor_dependency_kinds(executors)
    insert_executor_inbox_dependencies(executors.first(2_000))
    ApplicationRecord.lease_connection.execute(
      "ANALYZE task_executors, access_tokens, refresh_token_families, device_authorizations, agent_run_tasks"
    )

    source_scan = nil
    dependency_scan = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA" || payload[:cached]

      if sql.start_with?('SELECT "task_executors"."id"') &&
          sql.include?('ORDER BY "task_executors"."status" ASC')
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      elsif sql.start_with?('SELECT "task_executors"."id"') &&
          sql.include?("JOIN LATERAL")
        dependency_scan ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      assert_equal 0, TaskExecutor.reap(batch_size: 500)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert source_scan, "the public reaper must execute its bounded revoked source scan"
    assert dependency_scan, "the public reaper must lock and recheck the materialized ids"
    source_plan = explain(*source_scan)
    dependency_plan = explain(*dependency_scan)

    assert_match(
      /Index(?: Only)? Scan using index_task_executors_on_revoked_id/,
      source_plan
    )
    assert_match(/task_executors_pkey|index_task_executors_on_revoked_id/, dependency_plan)
    assert_match(/index_access_tokens_on_task_executor_id/, dependency_plan)
    assert_match(/index_refresh_token_families_on_executor_epoch/, dependency_plan)
    assert_match(/index_refresh_token_families_on_bound_runner_id/, dependency_plan)
    assert_match(/index_device_authorizations_on_task_executor_id/, dependency_plan)
    assert_match(/index_device_authorizations_on_expected_executor_and_status/, dependency_plan)
    # The inbox's two probes spell the frontier and claimant partial predicates exactly, so each is
    # an index probe, never a scan.
    assert_match(/index_agent_run_tasks_on_addressed_frontier/, dependency_plan)
    assert_match(/index_agent_run_tasks_on_claimant/, dependency_plan)
    assert_no_match(/Seq Scan on task_executors(?:\s|$)/, source_plan)
    assert_no_match(/Seq Scan on access_tokens(?:\s|$)/, dependency_plan)
    assert_no_match(/Seq Scan on refresh_token_families(?:\s|$)/, dependency_plan)
    assert_no_match(/Seq Scan on device_authorizations(?:\s|$)/, dependency_plan)
    assert_no_match(/Seq Scan on agent_run_tasks(?:\s|$)/, dependency_plan)
    assert_no_match(/Hash Anti Join/, dependency_plan)
  end

  test "executor reap locks its source window before probing and deleting" do
    executor = seed_executors(count: 1, blocked: 0).sole
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      statements << payload[:sql].to_s
    end
    begin
      assert_equal 1, TaskExecutor.reap(batch_size: 1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    source = statements.index do |sql|
      sql.start_with?('SELECT "task_executors"."id"') &&
        sql.include?('ORDER BY "task_executors"."status" ASC')
    end
    lock = statements.index { |sql| sql.include?("FOR UPDATE OF task_executors SKIP LOCKED") }
    probe = statements.index { |sql| sql.include?("JOIN LATERAL") }
    delete = statements.index { |sql| sql.start_with?('DELETE FROM "task_executors"') }

    assert source, "the revoked source window must be materialized first"
    assert lock, "the complete materialized window must be locked"
    assert probe, "durable dependencies must be checked after the row lock"
    assert delete, "eligible locked rows must be deleted directly"
    assert_operator source, :<, lock
    assert_operator lock, :<, probe
    assert_operator probe, :<, delete
    assert_not TaskExecutor.exists?(executor.id)
  end

  private

    def seed_families(count:, blocked:)
      executor = @account.task_executors.create!(
        executor_kind: :runner,
        display_name: "Family reap probe",
        registration_identifier: "family-reap-#{SecureRandom.hex(6)}",
        manager: @manager,
        assignment_scope: :user_private
      )
      executor.update_columns(credential_epoch: count + 1)
      created_at = @now - 60.days
      ids = RefreshTokenFamily.insert_all!(
        count.times.map do |index|
          {
            account_id: @account.id,
            access_token_name: "Retained family #{index}",
            task_executor_id: executor.id,
            credential_epoch: index + 1,
            last_used_at: @lapsed_at + index.fdiv(1_000_000),
            created_at: created_at,
            updated_at: created_at,
          }
        end,
        returning: %w[id]
      ).rows.flatten
      insert_refresh_dependencies(ids.first(blocked))
      RefreshTokenFamily.where(id: ids).order(:last_used_at, :id).to_a
    end

    def insert_refresh_dependencies(family_ids)
      prefix = SecureRandom.hex(5)
      RefreshToken.insert_all!(
        family_ids.map.with_index do |family_id, index|
          {
            account_id: @account.id,
            refresh_token_family_id: family_id,
            lookup_id: "rf#{prefix}#{index}",
            secret_digest: "retained",
            created_at: @now,
            updated_at: @now,
          }
        end
      )
    end

    def seed_executors(count:, blocked:)
      prefix = SecureRandom.hex(5)
      ids = TaskExecutor.insert_all!(
        count.times.map do |index|
          {
            account_id: @account.id,
            manager_id: @manager.id,
            executor_kind: "runner",
            display_name: "Retained executor #{index}",
            registration_identifier: "executor-reap-#{prefix}-#{index}",
            assignment_scope: "user_private",
            status: "revoked",
            credential_epoch: 1,
            applied_human_shutdown_generation:
              @manager.managed_resource_shutdown_generation,
            created_at: @now,
            updated_at: @now,
          }
        end,
        returning: %w[id]
      ).rows.flatten
      insert_executor_dependencies(ids.first(blocked))
      TaskExecutor.where(id: ids).order(:id).to_a
    end

    def seed_active_executors(count:)
      prefix = SecureRandom.hex(5)
      TaskExecutor.insert_all!(
        count.times.map do |index|
          {
            account_id: @account.id,
            manager_id: @manager.id,
            executor_kind: "runner",
            display_name: "Active executor #{index}",
            registration_identifier: "active-executor-#{prefix}-#{index}",
            assignment_scope: "user_private",
            status: "active",
            credential_epoch: 1,
            applied_human_shutdown_generation:
              @manager.managed_resource_shutdown_generation,
            created_at: @now,
            updated_at: @now,
          }
        end
      )
    end

    def insert_executor_dependencies(executor_ids)
      prefix = SecureRandom.hex(5)
      AccessToken.insert_all!(
        executor_ids.map.with_index do |executor_id, index|
          {
            account_id: @account.id,
            name: "Retained executor credential",
            source: "oauth_device",
            credential_plane: "executor_transport",
            lookup_id: "te#{prefix}#{index}",
            secret_digest: "retained",
            expires_at: @now + 1.year,
            task_executor_id: executor_id,
            credential_epoch: 1,
            created_at: @now,
            updated_at: @now,
          }
        end
      )
    end

    def insert_all_executor_dependency_kinds(executors)
      groups = executors.each_slice(1_000).to_a
      insert_executor_dependencies(groups.fetch(0).map(&:id))
      insert_executor_family_dependencies(groups.fetch(1))
      insert_executor_authorization_dependencies(groups.fetch(2))
      insert_executor_marker_dependencies(groups.fetch(3))
    end

    # The inbox's two holds on an executor: non-terminal rows addressed to it, and rows it claimed —
    # one loop's parked tool calls, half addressed only, half claimed too, in the status both
    # partial indexes cover.
    def insert_executor_inbox_dependencies(executors)
      agent_run = AgentRun.create!(
        workspace: workspaces(:shared), creating_user: @manager, status: "running",
        approval_mode: "bypass"
      )
      addressed, claimed = executors.each_slice((executors.length / 2.0).ceil).to_a
      AgentRunTask.insert_all!(
        addressed.map.with_index do |executor, index|
          inbox_row(agent_run, "addressed-#{index}", addressed_executor_id: executor.id)
        end +
        claimed.map.with_index do |executor, index|
          inbox_row(agent_run, "claimed-#{index}",
            addressed_executor_id: executor.id, claimed_by_executor_id: executor.id,
            claimed_by_executor_public_id: executor.public_id, claimed_at: @now)
        end
      )
    end

    def inbox_row(agent_run, node_key, **columns)
      {
        account_id: @account.id,
        agent_run_id: agent_run.id,
        node_key: node_key,
        type: AgentRunTasks::ToolTask.sti_name,
        status: "dispatched",
        authored_by: "model",
        addressed_role: "runner",
        claimed_by_executor_id: nil,
        claimed_by_executor_public_id: nil,
        claimed_at: nil,
        tool_name: "bash",
        started_at: @now,
        await_started_at: @now,
        created_at: @now,
        updated_at: @now,
        **columns,
      }
    end

    def insert_executor_family_dependencies(executors)
      RefreshTokenFamily.insert_all!(
        executors.map.with_index do |executor, index|
          {
            account_id: @account.id,
            access_token_name: "Executor family dependency #{index}",
            task_executor_id: executor.id,
            credential_epoch: executor.credential_epoch,
            last_used_at: @now,
            created_at: @now,
            updated_at: @now,
          }
        end
      )
    end

    def insert_executor_authorization_dependencies(executors)
      insert_device_authorizations(executors, marker: false)
    end

    def insert_executor_marker_dependencies(executors)
      insert_device_authorizations(executors, marker: true)
    end

    def insert_device_authorizations(executors, marker:)
      prefix = SecureRandom.hex(5)
      DeviceAuthorization.insert_all!(
        executors.map.with_index do |executor, index|
          row = {
            account_id: @account.id,
            client_id: OAuth::DEVICE_CLIENT_ID,
            registration_identifier: "dependency-#{prefix}-#{index}",
            runner_display_name: "Dependency probe",
            device_code_lookup_id: "da#{prefix}#{index}",
            device_code_digest: "retained",
            user_code: format("%08d", index),
            status: marker ? "connected" : "consumed",
            expires_at: @now + 1.day,
            created_at: @now,
            updated_at: @now,
          }
          if marker
            row[:expected_task_executor_public_id] = executor.public_id
          else
            row[:task_executor_id] = executor.id
          end
          row
        end
      )
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end
end
