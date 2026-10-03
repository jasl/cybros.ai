require "test_helper"

# Explicit, transactional measurement; no synthetic history survives the run.
# PARALLEL_WORKERS=1 bin/rails test test/benchmarks/task_lifetime.rb
class TaskLifetimeBenchmark < ActiveSupport::TestCase
  setup do
    @workspace, @human = workspaces(:shared), users(:member)
  end

  test "ordinary scheduling reads live work independently of retained history" do
    %w[standalone hosted].each do |host_kind|
      [100, 10_000].each do |size|
        agent_loop = waiting_loop(host_kind)
        AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
        now = Time.current
        AgentLoopNode.insert_all!(Array.new(size) do |index|
          { account_id: agent_loop.account_id, agent_loop_id: agent_loop.id, node_key: "history-#{index}",
            type: AgentLoopNodes::ToolTask.sti_name, status: "completed", on_failure: "absorb",
            authored_by: "model", transcript_visibility: "collapsed", completed_at: now,
            created_at: now, updated_at: now, tool_name: "read_file", tool_input: {} }
        end)
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
        samples = 3.times.map do
          measure { AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id) }
        end
        puts JSON.generate(operation: "ordinary_schedule", host: host_kind, retained_nodes: size, samples: samples)
      end
    end
  end

  test "exact original execution lookup and completion recovery use their bounded indexes" do
    account, workspace, human, agent = accounts(:cybros), workspaces(:shared), users(:member), users(:agent)
    parent = Conversation.create!(workspace: workspace, creating_user: human, answering_user: agent)
    seam = create_loop_backed_turn(conversation: parent, acting_user: human)
    source = seam.agent_loop.agent_loop_nodes.create!(type: AgentLoopNodes::ToolTask.sti_name,
      node_key: "r2t0", tool_name: "spawn", tool_input: {}, authored_by: "model")
    child = Conversation.create!(workspace: workspace, creating_user: agent, answering_user: agent,
      parent_conversation: parent, spawn_node: source)
    actor = Actors::Resolve.member(account: account, user: agent)
    now = Time.current
    ConversationTurn.insert_all!(Array.new(10_000) do |index|
      { account_id: account.id, conversation_id: child.id, position: index,
        kind: "direct_reply", role: "assistant", status: "completed", speaker_actor_id: actor.id,
        control_owner_user_id: agent.id, answering_user_id: agent.id, created_at: now, updated_at: now,
        sender_agent_loop_public_id: index == 9_999 ? seam.agent_loop.public_id : SecureRandom.uuid,
        sender_task_key: "r2t0" }
    end)
    AgentLoopNode.insert_all!(Array.new(10_000) do |index|
      { account_id: account.id, agent_loop_id: seam.agent_loop.id, node_key: "delegation-#{index}",
        type: AgentLoopNodes::DelegationTask.sti_name, status: index == 9_999 ? "running" : "completed",
        lifetime: "turn", detached: true, on_failure: "absorb", authored_by: "kernel",
        started_at: now, completed_at: index == 9_999 ? nil : now, created_at: now, updated_at: now }
    end)
    connection = ApplicationRecord.connection
    connection.execute("ANALYZE conversation_turns")
    connection.execute("ANALYZE agent_loop_nodes")

    turn = AgentLoops::Delegations.original_turn(child, source)
    assert_equal 9_999, turn.position
    original = child.conversation_turns.where(sender_agent_loop_public_id: seam.agent_loop.public_id,
      sender_task_key: source.node_key, forked_from_turn_public_id: nil).limit(1)
    frontier = AgentLoops::Delegations.recovery_candidates(after_id: source.id, limit: 200)
    [[:original_dispatch, original], [:completion_frontier, frontier]].each do |operation, scope|
      plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{scope.to_sql}")
      puts JSON.generate(operation: operation, history: 10_000, plan: JSON.parse(plan))
    end
  end

  private

    def waiting_loop(host_kind)
      return seed(ask("waiting")) if host_kind == "standalone"

      conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
        answering_user: users(:agent))
      agent_loop = create_loop_backed_turn(conversation: conversation, acting_user: @human,
        loop_status: "pending").agent_loop
      appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.authored(
        agent_loop: agent_loop, steps: [ask("waiting")], creator: @human))
      assert appended.applied?, appended.outcome.inspect
      agent_loop
    end

    def measure
      counts = { queries: 0, rows: 0 }
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].in?(%w[SCHEMA TRANSACTION CACHE])

        counts[:queries] += 1
        counts[:rows] += payload[:row_count].to_i
      end
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ApplicationRecord.uncached { yield }
      counts.merge(elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(3),
        allocations: GC.stat(:total_allocated_objects) - allocated)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
