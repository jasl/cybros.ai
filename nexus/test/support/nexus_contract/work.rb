module Nexus
  module Contract
    class << self
      private

        # The global readers wrap the same canonical Run and Task rows used
        # by workspace reads. The report renders its public immutable values,
        # with no database needed to generate the shared wire fixtures.
        def work
          workspace = Data.define(:public_id).new(public_id: "01900000-0000-7000-8000-000000000020")
          run = Data.define(:public_id, :workspace, :status, :details_pruned_at, :failure_reason,
            :turn_shape, :attention_reason, :created_at) do
            def standalone? = true
          end.new(
            public_id: "01900000-0000-7000-8000-0000000000b1", workspace:, status: "needs_attention",
            details_pruned_at: nil, failure_reason: nil,
            turn_shape: Run::TurnShape.new(status: "running", failure_reason_key: nil),
            attention_reason: "approval_required", created_at: Time.utc(2026, 10, 15)
          )
          node = CONTRACT_NODE_TYPE.new(id: 1, node_key: "r2t0", task_kind: "tool_task",
            status: "needs_approval", on_failure: "halt", tool_name: "write_file",
            transcript_visibility: "visible", created_at: Time.utc(2026, 10, 15))
          row = stringify_keys(AgentAPI::RunPresenter.basic(run))
          task = stringify_keys(AgentAPI::RunPresenter.task(node, live_server_ids: []))
          report = stringify_keys(AgentAPI::WorkReportPresenter.full(work_report_fixture))
          {
            "runs_path" => "/agent_api/v1/runs",
            "attention_path" => "/agent_api/v1/attention",
            "report_path" => "/agent_api/v1/work_report",
            "report_units" => WorkReports::Report::UNITS,
            "report_max_points" => ModelUsageRollups::UsageReport::MAX_POINTS,
            "attention_views" => %w[actionable following],
            "valid_runs_fixture" => { "runs" => [row], "pagination" => { "next_after" => nil } },
            "valid_attention_fixture" => {
              "items" => [{ "workspace_public_id" => workspace.public_id, "run_public_id" => run.public_id,
                            "conversation_public_id" => nil, "task" => task }],
              "pagination" => { "next_after" => nil },
            },
            "valid_report_fixture" => { "report" => report },
            "unknown_unit_fixture" => { "report" => report.merge("unit" => UNKNOWN_VALUE_FIXTURE) },
            "unknown_unit_behavior" => "carry_unknown",
            "amount_encoding" => "decimal_string",
          }
        end

        def work_report_fixture
          counters = ModelUsageTimeBucket::COUNTER_COLUMNS.index_with(0).merge(
            request_count: 3, input_tokens: 900, output_tokens: 120, total_tokens: 1020,
            cost_amount: BigDecimal("0.040500000000000001"), cost_known_request_count: 2
          )
          usage = ModelUsageRollups::UsageReport.allocate.send(:render_counters, counters)
          zero = ModelUsageRollups::UsageReport.allocate.send(:render_counters,
            ModelUsageTimeBucket::COUNTER_COLUMNS.index_with(0))
          from = Time.utc(2026, 10, 15)
          totals = WorkReports::Report::Totals.new(created_runs: 2, active_answering_agents: 1,
            conversation_usage: usage)
          WorkReports::Report::Snapshot.new(
            from:, to: from + 1.hour, unit: "hour", as_of: from + 2.hours, workspace_public_id: nil, agent_public_id: nil,
            current: WorkReports::Report::Current.new(
              run_counts: Run::STATUSES.index_with(0).merge("running" => 1, "needs_attention" => 1),
              attention_count: 1
            ),
            totals:,
            series: [WorkReports::Report::Point.new(bucket_start_at: from.iso8601,
              created_runs: 2, active_answering_agents: 1, conversation_usage: usage)],
            previous: WorkReports::Report::Previous.new(from: from - 1.hour, to: from,
              totals: WorkReports::Report::Totals.new(created_runs: 0, active_answering_agents: 0,
                conversation_usage: zero))
          )
        end
    end
  end
end
