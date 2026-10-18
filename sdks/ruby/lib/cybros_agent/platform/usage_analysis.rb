module CybrosAgent
  module Platform
    class ModelUsage
      include Api::UsageAnalysisProjections

      def analysis(from: nil, to: nil, group_by: nil, rank_by: nil, limit: nil,
        provider_id: nil, catalog_model_ref: nil, workload: nil, status: nil)
        params = query(from:, to:, group_by:, rank_by:, limit:, provider_id:, catalog_model_ref:, workload:, status:)
        shape(Api::ModelUsageAnalysis, @dispatch.call("/api/v1/admin/model_usage/analysis", params:), "analysis")
      end
    end
  end
end
