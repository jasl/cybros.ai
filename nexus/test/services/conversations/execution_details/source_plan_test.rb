require "test_helper"

class Conversations::ExecutionDetails::SourcePlanTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
  end

  test "loop retention stops its ordered source index at the batch cap" do
    variants = ConversationTurnVariant.insert_all!(Array.new(4_000) do |index|
      { account_id: @account.id, conversation_turn_id: @seam.turn.id,
        position: index + 1, status: "completed", source: "run", context_mode: "assembly" }
    end, returning: [:id]).rows.flatten
    variants.each_slice(500) do |ids|
      AgentRun.insert_all!(ids.map do |id|
        { account_id: @account.id, workspace_id: @workspace.id, creating_user_id: @human.id,
          conversation_turn_variant_id: id, status: "completed", approval_mode: "bypass",
          completed_at: 100.days.ago }
      end)
    end
    assert_source_plan("loops", "agent_runs", "prune_loop", "index_agent_runs_on_detail_retention")
  end

  test "direct invocation retention stops its ordered source index at the batch cap" do
    8.times do |batch|
      ModelInvocation.insert_all!(Array.new(500) do |index|
        { account_id: @account.id, creating_user_id: @human.id, conversation_id: @conversation.id,
          workload: "text_generation", purpose: "conversation_reply", provider_id: "dev", model_ref: "mock-text",
          internal_creation_key: "plan-#{batch}-#{index}", admission_deadline_seconds: 60,
          status: "completed", terminal_at: 100.days.ago }
      end)
    end
    assert_source_plan("invocations", "model_invocations", "prune_invocation", "index_model_invocations_on_detail_retention")
  end

  private

    def assert_source_plan(kind, table, method, index)
      ApplicationRecord.lease_connection.execute("ANALYZE #{table}")
      statement = nil
      subscriber = ->(_name, _started, _finished, _id, payload) do
        if payload[:sql].start_with?("SELECT") && payload[:sql].include?("FROM \"#{table}\"")
          statement ||= [payload[:sql], payload[:binds]]
        end
      end
      service = Conversations::ExecutionDetails::Prune.new(account: @account, kind: kind, batch: 25)
      result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        service.stub(method, false) { service.call }
      end
      assert_equal 25, result[:scanned]
      assert result.more?
      sql, binds = statement
      plan = ApplicationRecord.lease_connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds).join("\n")
      assert_match(/Limit.*actual.*rows=25/, plan)
      assert_match(/Index Scan using #{index}/, plan)
      assert_no_match(/\bSort\b|Bitmap|Seq Scan|Filter:/, plan)
    end
end
