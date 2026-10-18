module CybrosAgent
  module Platform
    UsageCounters = Data.define(:request_count, :input_tokens, :cache_read_tokens, :cache_creation_tokens,
      :output_tokens, :reasoning_tokens, :total_tokens, :cost_amount, :cost_complete)
    UsagePoint = Data.define(:bucket_start_at, *UsageCounters.members)
    UsageReport = Data.define(:unit, :series, :totals)

    module AdministrationProjections
      include Api::WorkspaceProjections
      include Api::Fields

      COUNTERS = { request_count: :integer, input_tokens: :integer, cache_read_tokens: :integer,
        cache_creation_tokens: :integer, output_tokens: :integer, reasoning_tokens: :integer,
        total_tokens: :integer, cost_amount: :string, cost_complete: :boolean }.freeze
      SHAPES = {
        UsageCounters => COUNTERS,
        UsagePoint => COUNTERS.merge(bucket_start_at: :string),
        UsageReport => { unit: :string, series: [:shapes, UsagePoint], totals: [:shape, UsageCounters] },
      }.freeze
    end

    class ModelUsage
      include AdministrationProjections

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def report(from:, to:, unit: nil, provider_id: nil, catalog_model_ref: nil, workload: nil, status: nil)
        params = query(from:, to:, unit:, provider_id:, catalog_model_ref:, workload:, status:)
        shape(UsageReport, @dispatch.call("/api/v1/admin/model_usage/report", params:), "report")
      end
    end
  end
end
