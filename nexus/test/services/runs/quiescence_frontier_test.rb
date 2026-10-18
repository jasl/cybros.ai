require "test_helper"

class Runs::QuiescenceFrontierTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  test "an unchanged schedule wake reads current work independently of completed history" do
    measurements = [100, 1_000].map do |history_size|
      run = waiting_loop
      add_history(run, history_size)

      measured = node_reads do
        Runs::ScheduleReady.call(run_id: run.id)
      end

      assert_equal "running", run.reload.status
      assert_equal "dispatched", run.tasks.find_by!(node_key: "waiting").status
      assert_operator measured.fetch(:instantiated), :<=, 4,
        "an idle wake must not instantiate #{history_size} completed tasks"
      measured
    end

    assert_equal measurements.first, measurements.last,
      "the number of returned rows and task objects follows current work, not retained history"
  end

  test "an unrelated expired tool does not make fallback load historical rounds" do
    run = waiting_loop
    add_history(run, 1_000)
    expired = run.tasks.find_by!(node_key: "history-1")
    expired.update_columns(status: "timed_out")

    measured = node_reads do
      assert_not Conversations::Compaction::Fallback.call(run.reload)
    end

    assert_operator measured.fetch(:rows), :<=, 2
    assert_operator measured.fetch(:instantiated), :<=, 1,
      "a timeout without a summary-source reference is not a compaction delegate"
    assert_equal "running", run.reload.status
  end

  test "a graceful drain waits for current work without loading completed history" do
    run = waiting_loop
    add_history(run, 1_000)
    waiting = run.tasks.find_by!(node_key: "waiting")
    stopped = Runs::Stop.call(Runs::Stop::Command.new(
      run: run, acting_user: @human, force: false
    ))
    assert_predicate stopped, :accepted?
    assert_equal "canceling", run.reload.status
    assert_equal "dispatched", waiting.reload.status,
      "a graceful drain leaves the existing rendezvous open"

    measured = node_reads do
      Runs::ScheduleReady.call(run_id: run.id)
    end

    assert_equal "canceling", run.reload.status
    assert_equal "dispatched", waiting.reload.status
    assert_operator measured.fetch(:instantiated), :<=, 1,
      "waiting for one started task must not instantiate 1,000 completed tasks"

    resolved = Runs::Parks::Settle.call(
      node: waiting, claim_token: waiting.resolution_token,
      outcome: "completed", content: "the last answer"
    )
    assert_predicate resolved, :applied?
    assert_equal "completed", waiting.reload.status
    assert_equal "canceled", run.reload.status,
      "the drain finishes as soon as its started work settles"
  end

  test "a fenced delegate stays outside the fallback read set" do
    run = waiting_loop
    add_history(run, 1_000)
    run.tasks.where(node_key: "history-1").update_all(
      status: "uncertain",
      compaction: { Conversations::Compaction::Fallback::DELEGATE_FALLBACK => "replacement" }
    )

    measured = node_reads do
      assert_not Conversations::Compaction::Fallback.call(run.reload)
    end

    assert_equal 0, measured.fetch(:rows)
    assert_equal 0, measured.fetch(:instantiated)
  end

  test "quiescence sees a deliverable settled through another instance" do
    run = waiting_loop
    assert_equal "dispatched", run.deliverable_node.status

    run.with_lock do
      # Load after the lock, so the association remains cached during the write.
      assert_equal "dispatched", run.deliverable_node.status
      node = Task.find(run.deliverable_node_id)
      Runs::Transition.node(node, status: "completed", completed_at: Time.current)
      Runs::EvaluateQuiescence.call(run)
    end

    assert_equal "completed", run.reload.status
    assert_predicate run, :delivered?
  end

  private

    def waiting_loop
      run = seed(ask("waiting"))
      started = Runs::Start.call(Runs::Start::Command.new(
        run: run, acting_user: @human
      ))
      assert_predicate started, :accepted?
      Runs::ScheduleReady.call(run_id: run.id)
      clear_enqueued_jobs
      run.reload
    end

    # Retained rounds and their completed tools dominate a long-running graph.
    # Bulk setup isolates the cost of the next wake from the cost of authoring history.
    def add_history(run, count)
      now = Time.current
      Task.insert_all!(Array.new(count) do |index|
        round = (index % 10).zero?
        {
          account_id: @account.id, run_id: run.id, node_key: "history-#{index}",
          type: round ? Tasks::ModelTask.sti_name : Tasks::ToolTask.sti_name,
          status: "completed", on_failure: "absorb", authored_by: "model",
          transcript_visibility: "collapsed", completed_at: now, created_at: now, updated_at: now,
          provider_id: round ? "dev" : nil, model_ref: round ? "mock-text" : nil,
          continuation_source: round ? "round" : nil,
          tool_name: round ? nil : "read_file", tool_input: {}, request_options: {},
          timeout_ms: round ? nil : 600_000,
        }
      end)
    end

    def node_reads(&block)
      counts = { rows: 0, instantiated: 0 }
      sql = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statement = payload[:sql].to_s
        next unless statement.start_with?("SELECT") && statement.include?("tasks")

        counts[:rows] += payload[:row_count].to_i
      end
      instances = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        counts[:instantiated] += payload.fetch(:record_count) if payload.fetch(:class_name) == "Task"
      end
      ApplicationRecord.uncached(&block)
      counts
    ensure
      ActiveSupport::Notifications.unsubscribe(sql)
      ActiveSupport::Notifications.unsubscribe(instances)
    end
end
