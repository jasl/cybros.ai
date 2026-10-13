require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Deployments::MaintenanceRaceTest < ActiveJob::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    @request = InferenceRequest.create!(account: @account, workspace: @workspace,
      creating_user: @human, workload: selection.workload)
    @invocation = DevModelLane.create_invocation!(inference_request: @request, selection: selection)
    @invocation.update!(status: "running")
    @attempt = @invocation.attempts.create!(account: @account, ordinal: 1,
      admission_shape: "admitted_free", deadline_at: 10.minutes.from_now)
    @agent_run = seed(tool("probe", "read_file"))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: @agent_run, acting_user: @human))
    AgentRuns::ScheduleReady.call(agent_run_id: @agent_run.id)
    @executor_id = suite_runner.id
    clear_enqueued_jobs
  end

  teardown do
    Account.where(id: @account.id).update_all(maintenance_started_at: nil)
    AgentRuns::Reap.destroy_aggregate(AgentRun.find(@agent_run.id)) if @agent_run
    ModelInvocationAttempt.where(model_invocation_id: @invocation.id).delete_all
    ModelInvocation.where(id: @invocation.id).delete_all
    InferenceRequest.where(id: @request.id).delete_all
    clear_enqueued_jobs
  end

  test "prepare waits for an accepted provider start to commit before counting it" do
    state = prepare_after_acceptance { start_provider }

    assert_equal 1, state.fetch(:model_attempts)
    assert_not state.fetch(:drained)
    assert_predicate @attempt.reload, :started?
  end

  test "prepare waits for an accepted executor claim to commit before counting it" do
    state = prepare_after_acceptance { claim_tool }

    assert_equal 1, state.fetch(:claimed_tools)
    assert_not state.fetch(:drained)
    assert_not_nil @agent_run.agent_run_tasks.sole.reload.claimed_at
  end

  test "prepare winning against a provider waiting for its invocation writes no start" do
    held = hold_row_lock(ModelInvocation, @invocation.id)
    starting = start_database_call { start_provider }
    wait_until_transitively_blocked_by(held.pid, starting.pid)
    assert Deployments::Maintenance.prepare.fetch(:drained)
    release_row_lock(held)
    held = nil

    assert_equal :deployment_maintenance, finish_database_call(starting).outcome
    starting = nil
    assert_predicate @attempt.reload, :prepared?
    assert_nil @attempt.provider_started_at
  ensure
    release_row_lock(held) if held
    stop_database_call(starting) if starting
  end

  test "prepare winning against a claimant waiting for its run writes no claim" do
    held = hold_row_lock(AgentRun, @agent_run.id)
    claiming = start_database_call { claim_tool }
    wait_until_transitively_blocked_by(held.pid, claiming.pid)
    assert Deployments::Maintenance.prepare.fetch(:drained)
    release_row_lock(held)
    held = nil

    assert_equal :task_not_claimable, finish_database_call(claiming).outcome
    claiming = nil
    assert_nil @agent_run.agent_run_tasks.sole.reload.claimed_at
  ensure
    release_row_lock(held) if held
    stop_database_call(claiming) if claiming
  end

  private

    def start_provider
      attempt = ModelInvocationAttempt.find(@attempt.id)
      invocation = attempt.model_invocation
      ModelInvocations::ProviderStart.call(attempt: attempt, host: "model_runner",
        base_url: ModelCatalog.provider_base_url(invocation.provider_id),
        profile: DevModelLane.profile_for_invocation(invocation))
    end

    def claim_tool
      Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: AgentRun.find(@agent_run.id), task_key: "probe",
        executor: TaskExecutor.find(@executor_id)
      ))
    end

    def prepare_after_acceptance
      accepted = Queue.new
      release = Queue.new
      admitting = start_database_call do
        ApplicationRecord.transaction do
          outcome = yield
          accepted << outcome
          release.pop
          outcome
        end
      end
      result = Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { accepted.pop }
      assert_includes [:started, :accepted], result.outcome

      # The owner's call has returned but its transaction has not committed.
      # The shared fence must still be held by that database connection.
      assert ApplicationRecord.connection_pool.with_connection { |connection|
        connection.select_value(<<~SQL)
          SELECT EXISTS (
            SELECT 1 FROM pg_locks
            WHERE pid = #{Integer(admitting.pid)}
              AND locktype = 'advisory' AND mode = 'ShareLock' AND granted
          )
        SQL
      }, "the admission fence must survive until the owning transaction commits"

      attempted = Queue.new
      observer = lambda do |*, payload|
        if Thread.current[:maintenance_prepare_probe] &&
            payload.fetch(:sql).include?("pg_try_advisory_xact_lock(")
          attempted << true
        end
      end
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record", observer)
      preparing = start_database_call do
        Thread.current[:maintenance_prepare_probe] = true
        Deployments::Maintenance.prepare
      ensure
        Thread.current[:maintenance_prepare_probe] = nil
      end
      Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { attempted.pop }
      assert_nil Deployments::Maintenance.started_at,
        "prepare cannot report a drain until the accepted start commits"
      assert preparing.thread.alive?

      release << true
      finish_database_call(admitting)
      admitting = nil
      state = finish_database_call(preparing)
      preparing = nil
      assert state.fetch(:active)
      state
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      release << true if admitting&.thread&.alive?
      stop_database_call(admitting) if admitting
      stop_database_call(preparing) if preparing
    end
end
