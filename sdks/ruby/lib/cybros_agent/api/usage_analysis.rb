module CybrosAgent
  module Api
    AnalysisPercentiles = Data.define(:sample_count, :missing_count, :p50, :p95)
    AnalysisCounters = Data.define(*Platform::UsageCounters.members, :amount_sample_count)
    AnalysisModelLatency = Data.define(:duration_ms, :time_to_first_token_ms)
    AnalysisGroup = Data.define(:value, :totals)
    AnalysisBreakdown = Data.define(:group_by, :rank_by, :limit, :total_group_count, :groups, :other)
    AnalysisModelUsage = Data.define(:totals, :status_counts, :latency, :breakdown)
    ModelUsageAnalysis = Data.define(:from, :to, :as_of, :cost_unit, :model_usage)
    AnalysisExecutionLatency = Data.define(:delivery_ms, :completion_ms)
    AnalysisToolGroup = Data.define(:tool_name, :task_count, :status_counts, :error_result_count, :latency)
    AnalysisTools = Data.define(:task_count, :status_counts, :error_result_count, :latency,
      :total_group_count, :groups, :other_task_count)
    AnalysisExecution = Data.define(:run_count, :retained_run_count, :details_pruned_run_count,
      :status_counts, :delivered_count, :undelivered_count, :completed_count, :uncompleted_count, :latency, :tools)
    WorkAnalysis = Data.define(*ModelUsageAnalysis.members, :workspace_public_id, :agent_public_id, :execution)

    module UsageAnalysisProjections
      include Parsing

      MODEL_ANALYSIS = {
        from: :string, to: :string, as_of: :string, cost_unit: :nullable_string,
        model_usage: [:shape, AnalysisModelUsage],
      }.freeze
      TOOL_TOTALS = { task_count: :integer, status_counts: :analysis_counts,
        error_result_count: :integer, latency: [:shape, AnalysisPercentiles] }.freeze
      SHAPES = {
        AnalysisPercentiles => { sample_count: :integer, missing_count: :integer,
          p50: :optional_integer, p95: :optional_integer },
        AnalysisCounters => Platform::AdministrationProjections::COUNTERS.merge(amount_sample_count: :integer),
        AnalysisModelLatency => { duration_ms: [:shape, AnalysisPercentiles],
          time_to_first_token_ms: [:shape, AnalysisPercentiles] },
        AnalysisGroup => { value: :string, totals: [:shape, AnalysisCounters] },
        AnalysisBreakdown => { group_by: :string, rank_by: :string, limit: :integer,
          total_group_count: :integer, groups: [:shapes, AnalysisGroup], other: [:shape, AnalysisCounters] },
        AnalysisModelUsage => { totals: [:shape, AnalysisCounters], status_counts: :analysis_counts,
          latency: [:shape, AnalysisModelLatency], breakdown: [:shape, AnalysisBreakdown] },
        ModelUsageAnalysis => MODEL_ANALYSIS,
        AnalysisExecutionLatency => { delivery_ms: [:shape, AnalysisPercentiles],
          completion_ms: [:shape, AnalysisPercentiles] },
        AnalysisToolGroup => TOOL_TOTALS.merge(tool_name: :string),
        AnalysisTools => TOOL_TOTALS.merge(total_group_count: :integer, groups: [:shapes, AnalysisToolGroup],
          other_task_count: :integer),
        AnalysisExecution => { run_count: :integer, retained_run_count: :integer, details_pruned_run_count: :integer,
          status_counts: :analysis_counts, delivered_count: :integer, undelivered_count: :integer,
          completed_count: :integer, uncompleted_count: :integer, latency: [:shape, AnalysisExecutionLatency],
          tools: [:shape, AnalysisTools] },
        WorkAnalysis => MODEL_ANALYSIS.merge(workspace_public_id: :nullable_string,
          agent_public_id: :nullable_string, execution: [:shape, AnalysisExecution]),
      }.freeze

      private

        # Keep unknown status words while validating each count at the wire boundary.
        def analysis_counts(hash, key)
          values = fetch_hash(hash, key)
          values.to_h { |name, _| [name, integer(values, name)] }.freeze
        end
    end
  end
end
