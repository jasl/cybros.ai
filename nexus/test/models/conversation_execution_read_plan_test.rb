require "test_helper"

class ConversationExecutionReadPlanTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
  end

  test "native windows and absent summaries stop at their ordered indexes" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
    speaker = Speakers::Resolve.member(account: @account, user: @user)
    now = Time.current
    Turn.insert_all!((0...10_000).map do |position|
      { account_id: @account.id, conversation_id: conversation.id, position: position,
        kind: "message", role: "user", status: "completed", visibility: "visible",
        speaker_id: speaker.id, control_owner_user_id: @user.id,
        answering_user_id: conversation.answering_user_id, created_at: now, updated_at: now }
    end)
    connection.execute("ANALYZE turns")
    statements = capture_selects do
      entries = conversation.timeline.entries(surface: :assembly, limit: 20, newest: true)
      assert_equal (9_980...10_000).to_a, entries.map(&:position)
      assert_nil conversation.timeline.compaction_position(surface: :assembly, kind: "compaction_summary")
    end
    plans = statements.filter_map { |sql, binds| explain(sql, binds) if sql.include?('FROM "turns"') }

    assert_equal 2, plans.length
    assert_ordered_window(plans.first, "index_turns_on_conversation_id_and_position", 20)
    assert_ordered_window(plans.last, "index_turns_on_completed_summaries", 0)
  end

  test "long run pages instantiate only tails and bounded rounds with indexed first reads" do
    runs = Array.new(12) { Run.create!(workspace: @workspace, creating_user: @user, approval_mode: "bypass") }
    now = Time.current
    runs.each do |run|
      # Interleaved tools keep the physical order representative of normal model/tool rounds.
      Task.insert_all!((1..500).flat_map do |round|
        (0..2).map do |slot|
          { account_id: @account.id, run_id: run.id,
            node_key: slot.zero? ? "r#{round}" : "r#{round}t#{slot}",
            type: slot.zero? ? Tasks::ModelTask.sti_name : Tasks::ToolTask.sti_name,
            status: "completed", authored_by: "model",
            continuation_source: slot.zero? ? "round" : nil,
            input_from_node_keys: slot.zero? && round > 1 ? ["r#{round - 1}"] : [],
            provider_id: slot.zero? ? "dev" : nil, model_ref: slot.zero? ? "mock-text" : nil,
            tool_name: slot.zero? ? nil : "read", created_at: now, updated_at: now }
        end
      end)
    end
    connection.execute("ANALYZE tasks")
    records = 0
    listener = ->(*args) { records += args.last.fetch(:record_count) }
    statements = capture_selects do
      ActiveSupport::Notifications.subscribed(listener, "instantiation.active_record") do
        selections = Runs::CurrentModel.for_loops(runs)
        assert_equal runs.map(&:id), selections.keys
        assert selections.values.all? { |task| task.node_key == "r500" }
      end
    end
    assert_equal runs.length, records, "historical model tasks must stay in SQL"
    tail_plan = explain(*statements.find { |sql, _| sql.include?("SELECT tail.*") })
    indexes = nodes(tail_plan).filter_map { |node| node["Index Name"] }
    assert_includes indexes, "index_tasks_on_mainline_order"
    assert_includes indexes, "index_tasks_on_mainline_first_read"
    follower = nodes(tail_plan).find { |node| node["Index Name"] == "index_tasks_on_mainline_first_read" }
    assert_includes follower.fetch("Index Cond"), "input_from_node_keys[1]",
      "the first-read equality must probe the index, including its C collation"
    assert_operator follower.fetch("Actual Rows"), :<=, 1

    statements = capture_selects do
      pages = Runs::Transcript.turn_rounds(runs, limit: 20)
      pages.each_value { |page| assert_equal (481..500).map { |n| "r#{n}" }, page.map { |row| row.fetch(:task_key) } }
    end
    round_plan = explain(*statements.find { |sql, _| sql.include?("SELECT selected.*") })
    assert_ordered_window(round_plan, "index_tasks_on_mainline_order", 20)
  end

  private

    def connection = ApplicationRecord.lease_connection

    def capture_selects
      statements = []
      listener = lambda do |*args|
        payload = args.last
        if !payload[:cached] && payload[:name] != "SCHEMA" && payload[:sql].start_with?("SELECT")
          statements << [payload[:sql], payload[:binds]]
        end
      end
      ApplicationRecord.uncached do
        ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { yield }
      end
      statements
    end

    def explain(sql, binds)
      JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "EXPLAIN", binds)).first.fetch("Plan")
    end

    def nodes(plan)
      [plan, *plan.fetch("Plans", []).flat_map { |child| nodes(child) }]
    end

    def assert_ordered_window(plan, index, rows)
      window = nodes(plan).find { |node| node["Node Type"] == "Limit" }
      assert_not_nil window, plan.inspect
      scan = window.fetch("Plans").sole
      assert_equal "Index Scan", scan.fetch("Node Type"), plan.inspect
      assert_equal index, scan.fetch("Index Name")
      assert_equal rows, scan.fetch("Actual Rows")
    end
end
