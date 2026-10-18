module AgentAPI
  class WorkAnalysisPresenter < ModelUsageAnalysisPresenter
    def self.full(report)
      super.merge(
        workspace_public_id: report.workspace_public_id,
        agent_public_id: report.agent_public_id,
        execution: {
          **report.execution.to_h.except(:latency, :tools),
          latency: report.execution.latency.to_h.transform_values(&:to_h),
          tools: {
            **report.execution.tools.to_h.except(:latency, :groups),
            latency: report.execution.tools.latency.to_h,
            groups: report.execution.tools.groups.map do |group|
              group.to_h.merge(latency: group.latency.to_h)
            end,
          },
        }
      )
    end
  end
end
