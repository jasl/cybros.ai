module AgentAPI
  class WorkReportPresenter
    def self.full(report)
      {
        from: report.from,
        to: report.to,
        unit: report.unit,
        as_of: report.as_of,
        workspace_public_id: report.workspace_public_id,
        agent_public_id: report.agent_public_id,
        current: report.current.to_h,
        totals: report.totals.to_h,
        series: report.series.map(&:to_h),
        previous: {
          from: report.previous.from,
          to: report.previous.to,
          totals: report.previous.totals.to_h,
        },
      }
    end
  end
end
