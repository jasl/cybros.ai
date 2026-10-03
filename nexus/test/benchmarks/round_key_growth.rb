require "test_helper"

# Run explicitly: PARALLEL_WORKERS=1 bin/rails test test/benchmarks/round_key_growth.rb
# The transaction rolls back synthetic history. Setup and warmup are outside each sample.
class RoundKeyGrowthBenchmark < ActiveSupport::TestCase
  test "measure key allocation against retained graph sizes" do
    [100, 1_000, 10_000].each do |size|
      agent_loop = graph(size)
      assert_equal size, agent_loop.agent_loop_nodes.count
      source = agent_loop.agent_loop_nodes.first
      calls = [{ "id" => "call", "name" => "read_file", "arguments" => "{}", "ordinal" => 0 }]
      allocators = {
        round: -> { AgentLoops::ExpandRound.new(agent_loop, source, calls) },
        wake: -> { AgentLoops::WakeContinuation.new(agent_loop, source, []) },
      }
      allocators.each do |name, allocate|
        agent_loop.with_lock { allocate.call }
        samples = 3.times.map { measure { agent_loop.with_lock { allocate.call } } }
        puts JSON.generate(operation: name, nodes: size, samples: samples)
      end
    end
  end

  private

    def graph(size)
      account = accounts(:cybros)
      agent_loop = AgentLoop.create!(account: account, workspace: workspaces(:shared),
        creating_user: users(:member), status: "running", started_at: Time.current, approval_mode: "bypass")
      now = Time.current
      AgentLoopNode.insert_all!(Array.new(size) do |index|
        round, fan = index.divmod(10)
        model = fan.zero?
        { account_id: account.id, agent_loop_id: agent_loop.id,
          node_key: model ? "r#{round + 1}" : "r#{round + 1}t#{fan - 1}",
          type: model ? AgentLoopNodes::ModelTask.sti_name : AgentLoopNodes::ToolTask.sti_name,
          status: "completed", on_failure: "absorb", authored_by: "model",
          transcript_visibility: "collapsed", completed_at: now, created_at: now, updated_at: now,
          provider_id: model ? "dev" : nil, model_ref: model ? "mock-text" : nil,
          continuation_source: model ? "round" : nil,
          tool_name: model ? nil : "read_file", tool_input: {}, request_options: {},
          timeout_ms: model ? nil : 600_000 }
      end)
      agent_loop
    end

    def measure
      counts = { queries: 0, rows: 0 }
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].in?(%w[SCHEMA TRANSACTION CACHE])

        counts[:queries] += 1
        counts[:rows] += payload[:row_count].to_i
      end
      GC.start
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ApplicationRecord.uncached { yield }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      counts.merge(elapsed_ms: (elapsed * 1_000).round(3), allocations: GC.stat(:total_allocated_objects) - allocated)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
