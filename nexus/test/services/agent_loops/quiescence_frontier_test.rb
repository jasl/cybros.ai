require "test_helper"

class AgentLoops::QuiescenceFrontierTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  test "an unchanged schedule wake reads current work independently of completed history" do
    measurements = [100, 1_000].map do |history_size|
      agent_loop = waiting_loop
      add_history(agent_loop, history_size)

      measured = node_reads do
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      end

      assert_equal "running", agent_loop.reload.status
      assert_equal "dispatched", agent_loop.agent_loop_nodes.find_by!(node_key: "waiting").status
      assert_operator measured.fetch(:instantiated), :<=, 4,
        "an idle wake must not instantiate #{history_size} completed tasks"
      measured
    end

    assert_equal measurements.first, measurements.last,
      "the number of returned rows and task objects follows current work, not retained history"
  end

  test "an unrelated expired tool does not make fallback load historical rounds" do
    agent_loop = waiting_loop
    add_history(agent_loop, 1_000)
    expired = agent_loop.agent_loop_nodes.find_by!(node_key: "history-1")
    expired.update_columns(status: "timed_out")

    measured = node_reads do
      assert_not Conversations::Compaction::Fallback.call(agent_loop.reload)
    end

    assert_operator measured.fetch(:rows), :<=, 2
    assert_operator measured.fetch(:instantiated), :<=, 1,
      "a timeout without a summary-source reference is not a compaction delegate"
    assert_equal "running", agent_loop.reload.status
  end

  test "a graceful drain waits for current work without loading completed history" do
    agent_loop = waiting_loop
    add_history(agent_loop, 1_000)
    waiting = agent_loop.agent_loop_nodes.find_by!(node_key: "waiting")
    stopped = AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
      agent_loop: agent_loop, acting_user: @human, force: false
    ))
    assert_predicate stopped, :accepted?
    assert_equal "canceling", agent_loop.reload.status
    assert_equal "dispatched", waiting.reload.status,
      "a graceful drain leaves the existing rendezvous open"

    measured = node_reads do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end

    assert_equal "canceling", agent_loop.reload.status
    assert_equal "dispatched", waiting.reload.status
    assert_operator measured.fetch(:instantiated), :<=, 1,
      "waiting for one started task must not instantiate 1,000 completed tasks"

    resolved = AgentLoops::Parks::Settle.call(
      node: waiting, claim_token: waiting.resolution_token,
      outcome: "completed", content: "the last answer"
    )
    assert_predicate resolved, :applied?
    assert_equal "completed", waiting.reload.status
    assert_equal "canceled", agent_loop.reload.status,
      "the drain finishes as soon as its started work settles"
  end

  test "a fenced delegate stays outside the fallback read set" do
    agent_loop = waiting_loop
    add_history(agent_loop, 1_000)
    agent_loop.agent_loop_nodes.where(node_key: "history-1").update_all(
      status: "uncertain",
      compaction: { Conversations::Compaction::Fallback::DELEGATE_FALLBACK => "replacement" }
    )

    measured = node_reads do
      assert_not Conversations::Compaction::Fallback.call(agent_loop.reload)
    end

    assert_equal 0, measured.fetch(:rows)
    assert_equal 0, measured.fetch(:instantiated)
  end

  test "quiescence sees a deliverable settled through another instance" do
    agent_loop = waiting_loop
    assert_equal "dispatched", agent_loop.deliverable_node.status

    agent_loop.with_lock do
      # Load after the lock, so the association remains cached during the write.
      assert_equal "dispatched", agent_loop.deliverable_node.status
      node = AgentLoopNode.find(agent_loop.deliverable_node_id)
      AgentLoops::Transition.node(node, status: "completed", completed_at: Time.current)
      AgentLoops::EvaluateQuiescence.call(agent_loop)
    end

    assert_equal "completed", agent_loop.reload.status
    assert_predicate agent_loop, :delivered?
  end

  private

    def waiting_loop
      agent_loop = seed(ask("waiting"))
      started = AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      ))
      assert_predicate started, :accepted?
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
      agent_loop.reload
    end

    # Retained rounds and their completed tools dominate a long-running graph.
    # Bulk setup isolates the cost of the next wake from the cost of authoring history.
    def add_history(agent_loop, count)
      now = Time.current
      AgentLoopNode.insert_all!(Array.new(count) do |index|
        round = (index % 10).zero?
        {
          account_id: @account.id, agent_loop_id: agent_loop.id, node_key: "history-#{index}",
          type: round ? AgentLoopNodes::ModelTask.sti_name : AgentLoopNodes::ToolTask.sti_name,
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
        next unless statement.start_with?("SELECT") && statement.include?("agent_loop_nodes")

        counts[:rows] += payload[:row_count].to_i
      end
      instances = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        counts[:instantiated] += payload.fetch(:record_count) if payload.fetch(:class_name) == "AgentLoopNode"
      end
      ApplicationRecord.uncached(&block)
      counts
    ensure
      ActiveSupport::Notifications.unsubscribe(sql)
      ActiveSupport::Notifications.unsubscribe(instances)
    end
end
