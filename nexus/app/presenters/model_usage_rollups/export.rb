module ModelUsageRollups
  # Administration reads aggregates only, never the receipt stream containing
  # member/workspace attribution available on the content-authorized surface.
  class Export < DiagnosticExport
    def initialize(account:, report:, filters:)
      @account = account
      @report = report
      @filters = filters
    end

    private

      def records
        yield envelope("export", format: "nexus.account.model_usage", version: 1,
          exported_at: Time.current.iso8601, scope: "account_aggregate", filters: @filters,
          consistency: "aggregate_snapshot", retention: { usage: "retained_receipts", content: "not_included" })
        yield envelope("summary", report: ModelUsageAnalysisPresenter.full(@report))
      end

      def envelope(type, **fields)
        { type: type, account_public_id: @account.public_id, **fields }
      end
  end
end
