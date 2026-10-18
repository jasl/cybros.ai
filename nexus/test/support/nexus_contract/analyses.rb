module Nexus
  module Contract
    class << self
      private

        def analyses
          admin = stringify_keys(ModelUsageAnalysisPresenter.full(model_analysis_fixture))
          member = stringify_keys(AgentAPI::WorkAnalysisPresenter.full(work_analysis_fixture))
          unknown_group = member.deep_dup
          unknown_group.fetch("model_usage").fetch("breakdown")["group_by"] = UNKNOWN_VALUE_FIXTURE
          unknown_rank = admin.deep_dup
          unknown_rank.fetch("model_usage").fetch("breakdown")["rank_by"] = UNKNOWN_VALUE_FIXTURE
          unknown_status = member.deep_dup
          unknown_status.fetch("model_usage").fetch("status_counts")[UNKNOWN_VALUE_FIXTURE] = 1
          unknown_status.fetch("execution").fetch("status_counts")[UNKNOWN_VALUE_FIXTURE] = 1
          unknown_status.fetch("execution").fetch("tools").fetch("status_counts")[UNKNOWN_VALUE_FIXTURE] = 1
          {
            "member_path" => "/agent_api/v1/work_analysis",
            "admin_path" => "/api/v1/admin/model_usage/analysis",
            "group_by_values" => ModelUsageRollups::Analysis::GROUPS,
            "rank_by_values" => ModelUsageRollups::Analysis::RANKS,
            "default_limit" => ModelUsageRollups::Analysis::DEFAULT_LIMIT,
            "max_limit" => ModelUsageRollups::Analysis::MAX_LIMIT,
            "max_window_days" => 90,
            "valid_member_fixture" => { "analysis" => member },
            "valid_admin_fixture" => { "analysis" => admin },
            "unknown_group_fixture" => { "analysis" => unknown_group },
            "unknown_rank_fixture" => { "analysis" => unknown_rank },
            "unknown_status_fixture" => { "analysis" => unknown_status },
            "unknown_value_behavior" => "carry_unknown",
            "amount_encoding" => "decimal_string",
            "percentile_method" => "nearest_rank",
            "elapsed_ms_rounding" => "floor",
            "window_fractional_digits" => 6,
          }
        end

        def model_analysis_fixture
          counters = ModelUsageRollups::Counters::COLUMNS.index_with(0).merge(
            request_count: 3, input_tokens: 900, output_tokens: 120, total_tokens: 1020,
            cost_amount: BigDecimal("0.040500000000000001"), cost_known_request_count: 2
          )
          total = ModelUsageRollups::Counters.render(counters).merge("amount_sample_count" => 2)
          group = ModelUsageRollups::Counters.render(counters.merge(request_count: 2, cost_known_request_count: 1))
            .merge("amount_sample_count" => 1)
          other = ModelUsageRollups::Counters.render(ModelUsageRollups::Counters::COLUMNS.index_with(0)
            .merge(request_count: 1, cost_known_request_count: 1)).merge("amount_sample_count" => 1)
          ModelUsageRollups::Analysis::Snapshot.new(
            from: Time.utc(2026, 10, 15), to: Time.utc(2026, 10, 16), as_of: Time.utc(2026, 10, 16, 1), cost_unit: "USD",
            model_usage: ModelUsageRollups::Analysis::Usage.new(
              totals: total, status_counts: { "succeeded" => 2, "failed" => 0, "discarded" => 0, "abandoned" => 1 },
              latency: ModelUsageRollups::Analysis::Latency.new(
                duration_ms: ModelUsageRollups::Percentiles::Sample.new(sample_count: 2, missing_count: 1, p50: 0, p95: 260),
                time_to_first_token_ms: ModelUsageRollups::Percentiles::Sample.new(sample_count: 0, missing_count: 3, p50: nil, p95: nil)
              ),
              breakdown: ModelUsageRollups::Analysis::Breakdown.new(
                group_by: "provider_id", rank_by: "request_count", limit: 1, total_group_count: 2,
                groups: [ModelUsageRollups::Analysis::Group.new(value: "dev", totals: group)], other:
              )
            )
          )
        end

        def work_analysis_fixture
          sample = ModelUsageRollups::Percentiles::Sample.new(sample_count: 1, missing_count: 1, p50: 42, p95: 42)
          tool_counts = Task::STATUSES.index_with(0).merge("completed" => 1, "failed" => 1)
          tool_group = WorkReports::Analysis::ToolGroup.new(
            tool_name: "read_file", task_count: 2, status_counts: tool_counts, error_result_count: 1, latency: sample
          )
          WorkReports::Analysis::Snapshot.new(
            **model_analysis_fixture.to_h, workspace_public_id: nil, agent_public_id: nil,
            execution: WorkReports::Analysis::Execution.new(
              run_count: 2, retained_run_count: 2, details_pruned_run_count: 0,
              status_counts: Run::STATUSES.index_with(0).merge("running" => 1, "completed" => 1),
              delivered_count: 1, undelivered_count: 1, completed_count: 1, uncompleted_count: 1,
              latency: WorkReports::Analysis::Latency.new(delivery_ms: sample, completion_ms: sample),
              tools: WorkReports::Analysis::Tools.new(
                **tool_group.to_h.except(:tool_name), total_group_count: 1, groups: [tool_group], other_task_count: 0
              )
            )
          )
        end
    end
  end
end
