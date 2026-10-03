require "test_helper"

class AgentLoops::Tasks::ApprovalDeadlineTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  [AgentLoops::Tasks::Approve, AgentLoops::Tasks::Deny].each do |verb|
    test "#{verb.name.demodulize} before the approval deadline still decides the task" do
      agent_loop, task = park!

      travel_to(task.deadline_at - 1.second, with_usec: true) do
        assert_predicate decide(verb, agent_loop), :accepted?
      end

      assert_equal "human", task.reload.approval_origin
      assert_not_nil task.approval_decided_at
      assert_not_equal "approval_expired", task.error_key
    end

    [0, 1.second].each do |lateness|
      test "#{verb.name.demodulize} at deadline plus #{lateness} expires without a sweep or an approval fact" do
        agent_loop, task = park!

        travel_to(task.deadline_at + lateness, with_usec: true) do
          assert_equal :not_awaiting_approval, decide(verb, agent_loop).outcome
          assert_equal %w[timed_out approval_expired], task.reload.values_at(:status, :error_key)
          assert_equal [nil, nil, nil, nil], task.values_at(
            :started_at, :approval_origin, :approved_by_user_id, :approval_decided_at
          )
          assert_equal %w[needs_attention halt_failure], agent_loop.reload.values_at(:status, :attention_reason)
          assert_enqueued_with(job: AgentLoops::ScheduleJob)

          # A repeat and the scheduled sweep cannot decide or narrate it again.
          count = agent_loop.conversation_event_items.count
          assert_equal :not_awaiting_approval, decide(verb, agent_loop).outcome
          assert_equal :idle, AgentLoops::Parks::Settle.call(node: task, timeout: true).outcome
          assert_equal count, agent_loop.conversation_event_items.count

          retried = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
            agent_loop: agent_loop, task_key: "probe", acting_user: @human
          ))
          assert_predicate retried, :accepted?
          AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
          assert_equal "needs_approval", task.reload.status
          assert_operator task.deadline_at, :>, Time.current
          assert_predicate decide(verb, agent_loop), :accepted?, "only an explicit retry renews the approval"
        end
      end
    end

    test "#{verb.name.demodulize} while paused uses the frozen approval clock" do
      agent_loop, task = park!
      assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?

      travel_to(task.deadline_at + 1.hour, with_usec: true) do
        assert_predicate decide(verb, agent_loop), :accepted?
        assert_equal "human", task.reload.approval_origin
        assert_not_equal "approval_expired", task.error_key
      end
    end
  end

  private

    def park!
      agent_loop = seed(tool("probe", "read_file", "on_failure" => "halt"), approval_mode: "ask",
        approval_rules: [{ "tool" => "read_file", "verdict" => "ask", "origin" => "author" }])
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
      task = agent_loop.agent_loop_nodes.find_by!(node_key: "probe")
      assert_equal "needs_approval", task.status
      [agent_loop, task]
    end

    def decide(verb, agent_loop)
      verb.call(verb::Command.new(agent_loop: agent_loop, task_key: "probe", acting_user: @human))
    end
end
