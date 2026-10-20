module CybrosAgent
  module Api
    RunCandidate = Data.define(:public_id, :workspace_public_id, :conversation_public_id, :turn_public_id, :status)
    AttentionItem = Data.define(:workspace_public_id, :run_public_id, :conversation_public_id, :task)
    WorkRunCounts = Data.define(:pending, :running, :paused, :needs_attention, :canceling, :completed, :canceled)
    WorkCurrent = Data.define(:run_counts, :attention_count)
    WorkTotals = Data.define(:created_runs, :active_answering_agents, :conversation_usage)
    WorkPoint = Data.define(:bucket_start_at, *WorkTotals.members)
    WorkPrevious = Data.define(:from, :to, :totals)
    WorkReport = Data.define(:from, :to, :unit, :as_of, :workspace_public_id, :agent_public_id, :current, :totals, :series, :previous)

    module WorkProjections
      include RunProjections

      TOTALS = { created_runs: :integer, active_answering_agents: :integer,
        conversation_usage: [:shape, Platform::UsageCounters] }.freeze
      SHAPES = {
        RunCandidate => RunCandidate.members.to_h { |name| [name, :string] },
        AttentionItem => { workspace_public_id: :string, run_public_id: :string,
          conversation_public_id: :nullable_string, task: [:shape, Task] },
        WorkRunCounts => WorkRunCounts.members.to_h { |name| [name, :integer] },
        WorkCurrent => { run_counts: [:shape, WorkRunCounts], attention_count: :integer },
        Platform::UsageCounters => Platform::AdministrationProjections::COUNTERS,
        WorkTotals => TOTALS,
        WorkPoint => TOTALS.merge(bucket_start_at: :string),
        WorkPrevious => { from: :string, to: :string, totals: [:shape, WorkTotals] },
        WorkReport => { from: :string, to: :string, unit: :string, as_of: :string,
          workspace_public_id: :nullable_string, agent_public_id: :nullable_string,
          current: [:shape, WorkCurrent], totals: [:shape, WorkTotals],
          series: [:shapes, WorkPoint], previous: [:shape, WorkPrevious] },
      }.freeze
    end

    # Queries over the member's currently readable work; each command still
    # belongs to the existing Workspace, Conversation, Run or Task handle.
    class WorkQueries
      include WorkProjections
      include UsageAnalysisProjections
      include Fields

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def runs(workspace_public_id: nil, after: nil, limit: nil, status: nil, attention: nil, order: nil,
               from: nil, to: nil, answering_user_public_id: nil, agent_public_id: nil, executor_public_id: nil, kind: nil)
        params = query(workspace_public_id:, after:, limit:, status: status && Array(status).join(","),
          attention:, order:, from:, to:, answering_user_public_id:, agent_public_id:, executor_public_id:, kind:)
        page(Run, @dispatch.call("/agent_api/v1/runs", params:), "runs")
      end

      def run_candidates(agent_public_id: nil, after: nil)
        page(RunCandidate, @dispatch.call("/agent_api/v1/run_candidates", params: query(agent_public_id:, after:)), "runs")
      end

      def attention(workspace_public_id: nil, view: nil, after: nil, limit: nil, order: nil)
        params = query(workspace_public_id:, view:, after:, limit:, order:)
        page(AttentionItem, @dispatch.call("/agent_api/v1/attention", params:), "items")
      end

      def report(workspace_public_id: nil, agent_public_id: nil, from: nil, to: nil, unit: nil)
        params = query(workspace_public_id:, agent_public_id:, from:, to:, unit:)
        shape(WorkReport, @dispatch.call("/agent_api/v1/work_report", params:), "report")
      end

      def analysis(workspace_public_id: nil, agent_public_id: nil, from: nil, to: nil,
        group_by: nil, rank_by: nil, limit: nil, provider_id: nil, catalog_model_ref: nil, workload: nil, status: nil)
        params = query(workspace_public_id:, agent_public_id:, from:, to:, group_by:, rank_by:, limit:,
          provider_id:, catalog_model_ref:, workload:, status:)
        shape(WorkAnalysis, @dispatch.call("/agent_api/v1/work_analysis", params:), "analysis")
      end
    end
  end
end
