class UsageExportsController < Work::BaseController
  include UsageAnalysisParameters
  include DiagnosticDownload

  def show
    window = report_window(unit: "day")
    return render_error(:window_invalid, t("usage_analysis.errors.window_invalid"), status: :bad_request) if window.invalid_parameter

    workspace = selected_workspace
    agent = selected_analysis_agent
    filters = analysis_filters
    result = WorkReports::Analysis.call(user: acting_user, workspace: workspace, agent: agent,
      from: window.from, to: window.to, filters: filters, **analysis_options)
    if result.outcome == :reported
      download_diagnostics(WorkReports::Export.new(user: acting_user, workspace: workspace, agent: agent,
        report: result.report, filters: filters), filename: "work-usage.jsonl.gz")
    else
      render_error(result.refusal, t("usage_analysis.errors.#{result.refusal}"), status: :bad_request)
    end
  end
end
