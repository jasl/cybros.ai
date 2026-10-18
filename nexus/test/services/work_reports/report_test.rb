require "test_helper"

class WorkReports::ReportTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @from = Time.utc(2026, 10, 10)
    @to = @from + 2.days
    @conversation = conversation
  end

  test "created cohorts, current statuses, and frozen answering agents have distinct meanings" do
    first = hosted_run(@conversation, created_at: @from)
    hosted_run(@conversation, created_at: @from + 1.hour)
    hosted_run(@conversation, created_at: @from + 1.day, answering_user: users(:member))
    Run.create!(workspace: @workspace, creating_user: users(:agent), status: "running",
      created_at: @from + 1.day, approval_mode: "bypass")
    old = Run.create!(workspace: @workspace, creating_user: @human, status: "paused",
      created_at: @from - 1.hour, attention_reason: "paused", approval_mode: "bypass")
    Run.create!(workspace: @workspace, creating_user: @human, status: "canceled",
      created_at: @to, approval_mode: "bypass")

    report = report_for.report

    assert_equal 4, report.totals.created_runs
    assert_equal 1, report.totals.active_answering_agents
    assert_equal [2, 2], report.series.map(&:created_runs)
    assert_equal [1, 0], report.series.map(&:active_answering_agents)
    assert_equal 1, report.current.run_counts.fetch("running")
    assert_equal 1, report.current.run_counts.fetch("paused")
    assert_equal 1, report.current.run_counts.fetch("canceled"), "current counts ignore the historical window"
    assert_equal 1, report.current.attention_count
    assert_equal 1, report.previous.totals.created_runs
    assert_equal 0, report.previous.totals.active_answering_agents
    assert_equal users(:agent), first.turn.answering_user, "answerer is the frozen Turn association"
    assert_equal old.created_at, @from - 1.hour
  end

  test "conversation receipts include retries and rolled rows but never unreadable or unrelated attribution" do
    hosted_run(@conversation, created_at: @from)
    invocation = SecureRandom.uuid_v7
    receipt(@conversation, input_tokens: 10, total_tokens: 12, cost_amount: "0.1",
      model_invocation_public_id: invocation)
    ModelUsageRollups::BackfillHourly.call
    receipt(@conversation, input_tokens: nil, total_tokens: nil, cost_amount: nil,
      model_invocation_public_id: invocation, attempt_ordinal: 2)
    hidden = conversation(creating_user: users(:owner), access_default: "none")
    private_conversation = conversation(workspace: workspaces(:personal))
    removed = conversation(tombstoned_at: Time.current)
    [hidden, private_conversation, removed, nil].each { |row| receipt(row, total_tokens: 900) }
    receipt(@conversation, recorded_at: @to, total_tokens: 900)
    receipt(@conversation, recorded_at: @from - 1.hour, total_tokens: 4, cost_amount: "0.2")

    report = report_for.report
    usage = report.totals.conversation_usage

    assert_equal 1, report.totals.created_runs
    assert_equal 2, usage.fetch("request_count"), "two attempts belong to one Run"
    assert_equal 10, usage.fetch("input_tokens")
    assert_equal 12, usage.fetch("total_tokens")
    assert_equal "0.1", usage.fetch("cost_amount")
    assert_equal false, usage.fetch("cost_complete")
    assert_equal [12, 0], report.series.map { |point| point.conversation_usage.fetch("total_tokens") }
    assert_equal 4, report.previous.totals.conversation_usage.fetch("total_tokens")
    @conversation.update!(archived_at: Time.current)
    assert_equal 2, report_for.report.totals.conversation_usage.fetch("request_count")
    @workspace.update!(access_mode: "private")
    assert_equal 0, report_for.report.totals.conversation_usage.fetch("request_count")
    assert_equal 0, report_for(workspace: @workspace).report.totals.created_runs
  end

  test "admin and agent stewardship add no content privilege and access changes affect history" do
    @conversation.update!(access_default: "none")
    hosted_run(@conversation, created_at: @from)
    receipt(@conversation, total_tokens: 42)
    report = report_for(user: users(:owner)).report
    assert_equal 0, report.totals.created_runs
    assert_equal 0, report.totals.conversation_usage.fetch("request_count")

    @conversation.conversation_access_entries.create!(user: users(:owner), level: "read")
    assert_equal 42, report_for(user: users(:owner)).report.totals.conversation_usage.fetch("total_tokens")
    @conversation.conversation_access_entries.find_by!(user: users(:owner)).update!(level: "none")
    assert_equal 0, report_for(user: users(:owner)).report.totals.created_runs
  end

  test "workspace selection preserves scope and SQL aggregates without loading the underlying work" do
    hosted_run(@conversation, created_at: @from)
    receipt(@conversation, total_tokens: 3)
    other = Workspace.create!(account: @human.account, creator: @human, owner: @human,
      name: "Other report scope", access_mode: "account_wide")
    foreign = conversation(workspace: other)
    hosted_run(foreign, created_at: @from)
    receipt(foreign, total_tokens: 9)

    report = nil
    assert_no_queries_match(/\ASELECT "(?:runs|usage_records|conversations)"\.\*/) do
      report = report_for(workspace: @workspace).report
    end
    assert_equal @workspace.public_id, report.workspace_public_id
    assert_equal 1, report.totals.created_runs
    assert_equal 3, report.totals.conversation_usage.fetch("total_tokens")
  end

  test "UTC alignment, supported units, finite windows, and quiet buckets use the report contract" do
    assert_equal :window_invalid, report_for(from: @from + 30.minutes).refusal
    assert_equal :unit_unsupported, report_for(unit: "month").refusal
    assert_equal :window_too_wide, report_for(to: @from + 1001.days).refusal
    report = report_for(from: @from, to: @from + 2.hours, unit: "hour").report
    assert_equal ["2026-10-10T00:00:00Z", "2026-10-10T01:00:00Z"], report.series.map(&:bucket_start_at)
    assert_equal [0, 0], report.series.map(&:created_runs)
    assert_equal true, report.totals.conversation_usage.fetch("cost_complete")
  end

  test "an agent report separates frozen answerers from receipt consumers inside the readable conversation scope" do
    agent = users(:agent)
    peer = users(:owner).stewarded_agents.create!(account: @human.account, kind: :agent,
      display_name: "Second report agent", agent_identifier: "report-peer")
    @conversation = conversation(creating_user: users(:owner), answering_user: peer)
    hosted_run(@conversation, created_at: @from, answering_user: agent)
    hosted_run(@conversation, created_at: @from, answering_user: peer)
    Run.create!(workspace: @workspace, creating_user: agent, status: "running",
      created_at: @from, approval_mode: "bypass")
    receipt(@conversation, consumer_user_public_id: agent.public_id, total_tokens: 17)
    receipt(@conversation, consumer_user_public_id: peer.public_id, total_tokens: 29)
    receipt(@conversation, consumer_user_public_id: @human.public_id, total_tokens: 41)
    hidden = conversation(creating_user: users(:owner), access_default: "none")
    hosted_run(hidden, created_at: @from, answering_user: agent)
    receipt(hidden, consumer_user_public_id: agent.public_id, total_tokens: 100)

    report = report_for(agent: agent).report
    assert_equal agent.public_id, report.agent_public_id
    assert_equal 2, report.totals.created_runs
    assert_equal 1, report.totals.active_answering_agents
    assert_equal 17, report.totals.conversation_usage.fetch("total_tokens")
    assert_equal 1, report.totals.conversation_usage.fetch("request_count")
    assert_equal 29, report_for(agent: peer).report.totals.conversation_usage.fetch("total_tokens")
    @conversation.update!(access_default: "none")
    assert_equal 0, report_for(agent: agent).report.totals.conversation_usage.fetch("request_count")
  end

  private

    def report_for(**options)
      WorkReports::Report.call(user: @human, from: @from, to: @to, unit: "day", **options)
    end

    def conversation(**options)
      Conversation.create!(workspace: @workspace, creating_user: @human,
        answering_user: users(:agent), **options)
    end

    def hosted_run(conversation, created_at:, answering_user: nil)
      seam = create_run_backed_turn(conversation:, acting_user: conversation.creating_user,
        answering_user:, turn_status: "completed", variant_status: "completed", run_status: "completed")
      seam.run.update_columns(created_at:)
      seam
    end

    def receipt(conversation, **options)
      UsageRecord.create!(account: @human.account, idempotency_key: SecureRandom.uuid_v7,
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        consumer_user_public_id: users(:agent).public_id,
        payer_user_public_id: users(:owner).public_id,
        workspace_public_id: conversation&.workspace&.public_id || @workspace.public_id,
        conversation_public_id: conversation&.public_id,
        provider_id: "dev", catalog_model_ref: "dev/text", wire_model_id: "text",
        workload: "text_generation", purpose: "task", service_class: "interactive",
        admission_shape: "priced", status: "succeeded", recorded_at: @from + 1.hour,
        cost_unit: "USD", **options)
    end
end
