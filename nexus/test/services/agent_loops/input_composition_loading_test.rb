require "test_helper"

class AgentLoops::InputCompositionLoadingTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
  end

  # A step reads what it names, in one batch however long the list: the rows, and the stages they
  # sit behind — never a query per named result.
  test "a reader naming a longer list of results reads it in the same queries" do
    counts = [1, 32].map do |length|
      materials = Array.new(length) { |index| tool("material-#{index}", "read_file") }
      agent_loop = seed(*materials,
        model("reader", "results" => Array.new(length) { |index| "material-#{index}" }))
      reader = agent_loop.agent_loop_nodes.find_by!(node_key: "reader")
      measurements, sources = measure { AgentLoops::InputComposition.new(node: reader, input: nil).delivered_sources }
      assert_equal length, sources.length
      measurements.fetch(:queries)
    end
    assert_equal counts.first, counts.last, "one batch, not a query per named result"
  end

  test "a detached result does not reload history before the mainline round that spawned it" do
    counts = [1, 16].map do |history|
      agent_loop = seed(*Array.new(history) { |index| model("old-#{index}") }, model("origin"), model("current"))
      agent_loop.agent_loop_nodes.update_all(status: "completed", completed_at: Time.current)
      agent_loop.update!(status: "running")
      origin = agent_loop.agent_loop_nodes.find_by!(node_key: "origin")
      appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
        agent_loop: agent_loop, origin: "kernel",
        steps: [AgentLoops::Tasks::Step::Model.new(key: "background", model: MOCK_MODEL)],
        tip: kernel_tip(origin, [origin], [], AgentLoops::Tasks::Compile::BRANCH, true)
      ))
      assert_predicate appended, :applied?, appended.outcome.inspect
      agent_loop.agent_loop_nodes.find_by!(node_key: "background")
        .update_columns(status: "completed", completed_at: Time.current)
      key = AgentLoops::WakeContinuation.call(agent_loop: agent_loop)
      reader = agent_loop.agent_loop_nodes.find_by!(node_key: key)

      measurements, sources = measure { AgentLoops::InputComposition.sources_for(reader) }
      assert_equal %w[current background], sources.map(&:node_key)
      measurements
    end
    assert_equal counts.first, counts.last,
      "the old mainline round's sealed request owns its earlier history"
  end

  # A reader naming a race of [tool, stage] arms reads the race's selection: one walk to the
  # winner, however many arms raced.
  test "a race reader composes in the same queries, whatever the number of arms" do
    DevModelLane.ensure_enabled!(accounts(:cybros))
    counts = [2, 8].to_h do |width|
      report = settled_stage_race_follower(width)
      measurements, composition = measure do
        AgentLoops::InputComposition.call(node: report, input: report.input_value)
      end
      assert_predicate composition, :composed?, composition.refusal.inspect
      [width, measurements.fetch(:queries)]
    end

    assert_equal counts.fetch(2), counts.fetch(8), "the read does not grow with the arms: #{counts.inspect}"
  end

  private

    # `width` probes, each wrapped by a stage that ends its arm, raced; the first arm wins and the
    # rest are canceled before the follower composes.
    def settled_stage_race_follower(width)
      arms = Array.new(width) do |index|
        [tool("t#{index}", "read_file"),
         { "script" => { "key" => "s#{index}", "script" => "return results[0].output;", "results" => ["t#{index}"] } }]
      end
      agent_loop = seed(parallel(*arms, until: "any", key: "race"),
        model("report", "results" => ["race"]))
      started = AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
      assert_predicate started, :accepted?
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      settled = AgentLoops::Parks::Settle.call(node: agent_loop.agent_loop_nodes.find_by!(node_key: "t0"),
        trusted: true, outcome: "completed", content: "T0")
      assert_predicate settled, :applied?
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      stage = agent_loop.agent_loop_nodes.find_by!(node_key: "s0")
      AgentLoops::ScriptJob.perform_now(stage.id, stage.execution_generation)
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      assert_equal "completed", agent_loop.agent_loop_nodes.find_by!(node_key: "race").status
      agent_loop.agent_loop_nodes.find_by!(node_key: "report")
    end

    def measure
      counts = { queries: 0, records: 0 }
      queries = ->(*, payload) { counts[:queries] += 1 unless payload[:cached] || payload[:name] == "SCHEMA" }
      records = ->(*, payload) { counts[:records] += payload.fetch(:record_count) }
      sources = nil
      ActiveSupport::Notifications.subscribed(queries, "sql.active_record") do
        ActiveSupport::Notifications.subscribed(records, "instantiation.active_record") do
          ApplicationRecord.uncached { sources = yield }
        end
      end
      [counts, sources]
    end
end
