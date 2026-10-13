require "test_helper"
require_relative "../../../test_helpers/turn_convergence_test_helper"

class Conversations::Turns::ConvergeFrontierTest < ActiveSupport::TestCase
  include TurnConvergenceTestHelper

  BATCH = 200
  SOURCE_INDEXES = {
    "model_invocations" => "index_model_invocations_on_terminal_replies_owed",
    "conversation_turn_variants" => "index_conversation_turn_variants_settle_frontier",
    "agent_runs" => "index_agent_runs_stop_frontier",
  }.freeze

  test "both recovery pages stop each source index and probe only their captured pairs" do
    seed_running_pairs(1_000)
    seed_terminal_replies
    ApplicationRecord.lease_connection.execute(
      "ANALYZE conversations, conversation_turns, conversation_turn_variants, agent_runs, model_invocations"
    )
    cursors = {}

    2.times do
      pass = nil
      statements = capture_frontiers do
        pass = Conversations::Turns::Converge.call(batch: BATCH, cursors: cursors).value
      end
      assert_equal BATCH * 4, pass[:scanned]
      assert_equal BATCH, pass[:recorded], "only terminal replies need updates; all loop pairs are healthy"
      assert_predicate pass, :more?
      pass.cursor.each do |phase, after|
        assert_operator after, :>, cursors.fetch(phase, 0), "#{phase} advances independently"
      end
      cursors = pass.cursor

      sources, matching = statements.partition { |sql, _binds| source_statement?(sql) }
      assert_equal 4, sources.length, "one source query for each phase"
      assert_equal 3, matching.length, "each loop arm applies only to its captured source ids"
      sources.each do |statement|
        table = statement.first.match(/FROM "([^"]+)"/)[1]
        assert_source_plan(explain(statement), SOURCE_INDEXES.fetch(table))
      end
      matching.each { |statement| assert_matching_plan(explain(statement)) }
    end
  end

  private

    def seed_terminal_replies
      now = Time.current
      conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))
      common = {
        account_id: conversation.account_id, workspace_id: conversation.workspace_id,
        creating_user_id: conversation.creating_user_id, conversation_id: conversation.id,
        workload: "text_generation", purpose: "conversation_reply", provider_id: "dev", model_ref: "mock-text",
        admission_deadline_seconds: 600, status: "completed", terminal_at: now,
        created_at: now, updated_at: now,
      }
      prefix = SecureRandom.hex(8)
      # Settled history makes the partial source index decisive. After two
      # real 200-row applies, EXPLAIN still sees more than one full owed page.
      ModelInvocation.insert_all!(Array.new(7_700) do |index|
        common.merge(internal_creation_key: "#{prefix}-#{index}",
          terminal_event_recorded_at: index < 7_000 ? now : nil)
      end)
    end

    def capture_frontiers
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload.fetch(:sql)
        next if payload[:cached]

        if source_statement?(sql) || sql.start_with?("SELECT matched.agent_run_id, matched.conversation_id")
          statements << [sql.dup, payload.fetch(:binds).dup]
        end
      end
      ApplicationRecord.uncached { yield }
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def source_statement?(sql)
      sql.start_with?('SELECT "model_invocations"."id", "model_invocations"."conversation_id",') ||
        sql.start_with?('SELECT "conversation_turn_variants"."id" FROM "conversation_turn_variants"') ||
        sql.start_with?('SELECT "agent_runs"."id" FROM "agent_runs"')
    end

    def explain(statement)
      sql, binds = statement
      result = ApplicationRecord.lease_connection.select_value(
        "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "EXPLAIN", binds
      )
      JSON.parse(result).sole.fetch("Plan")
    end

    def assert_source_plan(plan, index)
      message = JSON.pretty_generate(plan)
      assert_equal "Limit", plan.fetch("Node Type"), message
      assert_equal BATCH, plan.fetch("Actual Rows"), message
      scan = plan.fetch("Plans").sole
      assert_includes ["Index Scan", "Index Only Scan"], scan.fetch("Node Type"), message
      assert_equal index, scan.fetch("Index Name"), message
      assert_equal "Forward", scan.fetch("Scan Direction"), message
      assert_equal BATCH, scan.fetch("Actual Rows"), message
      assert_equal 1, scan.fetch("Actual Loops"), message
      assert_match(/>=/, scan.fetch("Index Cond"), message)
      assert_empty scan.fetch("Plans", []), message
      assert_not scan.key?("Filter"), message
    end

    def assert_matching_plan(plan)
      message = JSON.pretty_generate(plan)
      assert_equal 0, plan.fetch("Actual Rows"), message
      nodes = plan_nodes(plan)
      frontier = nodes.select { |node| node.fetch("Node Type") == "Function Scan" }.sole
      assert_equal BATCH, frontier.fetch("Actual Rows"), message
      assert_equal 1, frontier.fetch("Actual Loops"), message
      scans = nodes.select { |node| node.key?("Relation Name") }
      assert_not_empty scans, message
      scans.each do |scan|
        assert_includes ["Index Scan", "Index Only Scan"], scan.fetch("Node Type"), message
        assert_operator scan.fetch("Actual Loops"), :<=, BATCH, message
        assert_operator scan.fetch("Actual Rows"), :<=, 1, message
        assert scan.key?("Index Cond"), message
      end
      assert_not nodes.any? { |node| node.fetch("Node Type").match?(/Sort|Bitmap|Seq Scan/) }, message
    end

    def plan_nodes(plan)
      [plan, *plan.fetch("Plans", []).flat_map { |child| plan_nodes(child) }]
    end
end
