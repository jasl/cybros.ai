require "test_helper"

class Runs::Tasks::ApprovalDeadlineTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  [Runs::Tasks::Approve, Runs::Tasks::Deny].each do |verb|
    test "#{verb.name.demodulize} before the approval deadline still decides the task" do
      run, task = park!

      travel_to(task.deadline_at - 1.second, with_usec: true) do
        assert_predicate decide(verb, run), :accepted?
      end

      assert_equal "human", task.reload.approval_origin
      assert_not_nil task.approval_decided_at
      assert_not_equal "approval_expired", task.error_key
    end

    [0, 1.second].each do |lateness|
      test "#{verb.name.demodulize} at deadline plus #{lateness} expires without a sweep or an approval fact" do
        run, task = park!

        travel_to(task.deadline_at + lateness, with_usec: true) do
          assert_equal :not_awaiting_approval, decide(verb, run).outcome
          assert_equal %w[timed_out approval_expired], task.reload.values_at(:status, :error_key)
          assert_equal [nil, nil, nil, nil], task.values_at(
            :started_at, :approval_origin, :approved_by_user_id, :approval_decided_at
          )
          assert_equal %w[needs_attention halt_failure], run.reload.values_at(:status, :attention_reason)
          assert_enqueued_with(job: Runs::ScheduleJob)

          # A repeat and the scheduled sweep cannot decide or narrate it again.
          count = run.event_items.count
          assert_equal :not_awaiting_approval, decide(verb, run).outcome
          assert_equal :idle, Runs::Parks::Settle.call(node: task, timeout: true).outcome
          assert_equal count, run.event_items.count

          retried = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
            run: run, task_key: "probe", acting_user: @human
          ))
          assert_predicate retried, :accepted?
          Runs::ScheduleReady.call(run_id: run.id)
          assert_equal "needs_approval", task.reload.status
          assert_operator task.deadline_at, :>, Time.current
          assert_predicate decide(verb, run), :accepted?, "only an explicit retry renews the approval"
        end
      end
    end

    test "#{verb.name.demodulize} while paused uses the frozen approval clock" do
      run, task = park!
      assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(
        run: run, acting_user: @human
      )), :accepted?

      travel_to(task.deadline_at + 1.hour, with_usec: true) do
        assert_predicate decide(verb, run), :accepted?
        assert_equal "human", task.reload.approval_origin
        assert_not_equal "approval_expired", task.error_key
      end
    end
  end

  private

    def park!
      run = seed(tool("probe", "read_file", "on_failure" => "halt"), approval_mode: "ask",
        approval_rules: [{ "tool" => "read_file", "verdict" => "ask", "origin" => "author" }])
      assert_predicate Runs::Start.call(Runs::Start::Command.new(
        run: run, acting_user: @human
      )), :accepted?
      Runs::ScheduleReady.call(run_id: run.id)
      clear_enqueued_jobs
      task = run.tasks.find_by!(node_key: "probe")
      assert_equal "needs_approval", task.status
      [run, task]
    end

    def decide(verb, run)
      verb.call(verb::Command.new(run: run, task_key: "probe", acting_user: @human))
    end
end
