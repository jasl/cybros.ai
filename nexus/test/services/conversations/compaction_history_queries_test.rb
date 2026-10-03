require "test_helper"

class Conversations::CompactionHistoryQueriesTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
      answering_user: @agent)
    _turn, @agent_loop = materialize_loop_reply!(conversation, agent: @human,
      text: "Keep this original question", model_ref: "mock-windowless")
    schedule_loop!(@agent_loop)
  end

  test "compaction reads a growing round chain in batches without loading tool result bodies" do
    2.times { |index| complete_tool_round(index) }
    _small_history, small_queries = read_history

    10.times { |index| complete_tool_round(index + 2) }
    history, large_queries = read_history

    assert_equal (1..12).map { |index| "r#{index}" }, history.rounds.map(&:node_key)
    assert_equal 12, history.entries.length
    assert_includes history.entries.first, "Keep this original question"
    history.entries.each_with_index do |entry, index|
      assert_includes entry, "working on file #{index}"
      assert_includes entry, "file_#{index}.txt"
      assert_includes entry, "Tool read_file (completed, ok)"
      assert_not_includes entry, "PRIVATE RESULT #{index}"
    end
    assert_operator large_queries.length, :<=, small_queries.length + 3,
      "compaction grew from 2 to 12 rounds: #{small_queries.length} -> #{large_queries.length} queries\n" \
      "#{large_queries.join("\n")}"
  end

  test "the chain probes only its read keys beside unrelated model branches" do
    2.times { |index| complete_tool_round(index) }
    source = loop_node(@agent_loop, "r1")
    common = source.attributes.except("id", "public_id", "node_key").merge(
      "input_from_node_keys" => [], "selected_model_invocation_id" => nil,
      "continuation_source" => AgentLoopNodes::ModelTask::BRANCH
    )
    # Representative graph metadata only: unrelated branches must not
    # enter this chain's recursive source or any model-body preload.
    AgentLoopNode.insert_all!(Array.new(10_000) { |index| common.merge("node_key" => "aside_#{index}") })
    ApplicationRecord.lease_connection.execute("ANALYZE agent_loop_nodes")

    statements = []
    capture = lambda do |*, payload|
      if !payload[:cached] && payload[:sql].start_with?("WITH RECURSIVE history")
        statements << [payload.fetch(:sql).dup, payload.fetch(:binds).dup]
      end
    end
    history = nil
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { history, = read_history }
    assert_equal %w[r1 r2], history.rounds.map(&:node_key)
    assert_equal 1, statements.length

    sql, binds = statements.sole
    result = ApplicationRecord.lease_connection.select_value(
      "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "EXPLAIN", binds
    )
    plan = JSON.parse(result).sole.fetch("Plan")
    message = JSON.pretty_generate(plan)
    assert_equal 2, plan.fetch("Actual Rows"), message
    scans = plan_nodes(plan).select { |part| part["Relation Name"] == "agent_loop_nodes" }
    assert_not_empty scans, message
    scans.each do |scan|
      assert_includes ["Index Scan", "Index Only Scan"], scan.fetch("Node Type"), message
      assert_operator scan.fetch("Actual Rows"), :<=, 1, message
      assert scan.key?("Index Cond"), message
    end
    keyed = scans.find { |scan| scan["Index Name"] == "index_agent_loop_nodes_on_agent_loop_id_and_node_key" }
    assert_not_nil keyed, message
    assert_match(/agent_loop_id.*node_key/, keyed.fetch("Index Cond"), message)
    assert_not plan_nodes(plan).any? { |part| part.fetch("Node Type").match?(/Seq Scan|Bitmap|Hash/) }, message
  end

  test "an arrived summary cuts the chain before older rounds are loaded" do
    2.times { |index| complete_tool_round(index) }
    compact_history
    run_loop_round!(@agent_loop, sse_success("SUMMARY OF EARLIER FILES"))
    complete_tool_round(2)

    history, = read_history
    assert_equal ["r3"], history.rounds.map(&:node_key)
    assert_includes history.entries.sole, "SUMMARY OF EARLIER FILES"
    assert_includes history.entries.sole, "working on file 2"
    assert_not_includes history.entries.sole, "Keep this original question"
    assert_not_includes history.entries.sole, "working on file 0"
    assert_not_includes history.entries.sole, "working on file 1"
  end

  test "a failed summary resumes the chain behind the marked round" do
    2.times { |index| complete_tool_round(index) }
    compact_history
    (Conversations::Compaction::Summarizer::RETRIES + 1).times do
      run_loop_round!(@agent_loop, json_response(400, { "error" => "summary refused" }))
    end
    assert_equal "failed", loop_node(@agent_loop, "k1").status
    complete_tool_round(2)

    history, = read_history
    assert_equal %w[r1 r2 r3], history.rounds.map(&:node_key)
    assert_includes history.entries.first, "Keep this original question"
    assert_not_includes history.entries.join("\n"), Conversations::Compaction::Serialize::SUMMARY_LEAD
  end

  test "the first declared model source wins over an older model branch" do
    older = append_model("older", AgentLoops::Tasks::Tip.seed(AgentLoopNodes::ModelTask::BRANCH))
    first = loop_node(@agent_loop, "r1")
    spine = append_model("spine", kernel_tip(first, [first]))
    reader = append_model("reader", kernel_tip(spine, [spine], [older]))

    assert_operator older.id, :<, spine.id
    assert_equal %w[spine older], reader.input_from_node_keys
    assert_equal %w[r1 spine], Conversations::Compaction::Serialize.chain(reader).map(&:node_key)
  end

  [" ", false].each do |mark|
    test "a policy with blank summary source #{mark.inspect} keeps earlier authored history" do
      agent_loop = seed(
        model("first", "prompt" => "Keep the earliest authored question"),
        model("middle", "prompt" => "Continue the earlier work",
          "compaction" => { "mode" => "kernel", "summary_source" => mark }),
        model("reader"), workspace: workspaces(:shared)
      )
      middle = loop_node(agent_loop, "middle")
      assert_equal mark, middle.compaction.fetch("summary_source"), "the authoring boundary retains this policy"
      assert_nil middle.arrived_summary

      history = Conversations::Compaction::Serialize.loop_history(loop_node(agent_loop, "reader"))
      assert_equal %w[first middle], history.rounds.map(&:node_key)
      assert_includes history.entries.first, "Keep the earliest authored question"
      assert_includes history.entries.last, "Continue the earlier work"
    end
  end

  private

    def complete_tool_round(index)
      schedule_loop!(@agent_loop)
      call_id = "call_#{index}"
      run_loop_round!(@agent_loop, sse_success("working on file #{index}", tool_calls: [
        { id: call_id, name: "read_file", arguments: { path: "file_#{index}.txt" }.to_json },
      ]))
      settled = AgentLoops::Parks::Settle.call(
        node: @agent_loop.agent_loop_nodes.find_by!(tool_call_id: call_id), trusted: true,
        content: "PRIVATE RESULT #{index}", outcome: "completed"
      )
      assert_predicate settled, :applied?
      clear_enqueued_jobs
    end

    def read_history
      node = next_round
      ApplicationRecord.connection_pool.clear_query_cache
      queries = []
      capture = lambda do |*, payload|
        queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      end
      history = ApplicationRecord.uncached do
        ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
          Conversations::Compaction::Serialize.loop_history(node)
        end
      end
      [history, queries]
    end

    def next_round
      @agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name, status: "queued").sole
    end

    def compact_history
      result = AgentLoops::Tasks::Compact.call(AgentLoops::Tasks::Compact::Command.new(
        agent_loop: @agent_loop, task_key: next_round.node_key, acting_user: @human
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      schedule_loop!(@agent_loop)
    end

    def append_model(key, tip)
      result = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
        agent_loop: @agent_loop,
        steps: [AgentLoops::Tasks::Step::Model.new(key: key, model: MOCK_MODEL, prompt: key)],
        tip: tip, origin: "kernel"
      ))
      assert_predicate result, :applied?, result.outcome.inspect
      loop_node(@agent_loop, key)
    end

    def plan_nodes(plan)
      [plan, *plan.fetch("Plans", []).flat_map { |child| plan_nodes(child) }]
    end
end
