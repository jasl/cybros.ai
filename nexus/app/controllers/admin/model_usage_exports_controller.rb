class Admin::ModelUsageExportsController < Admin::BaseController
  include APIErrors
  include UsageAnalysisParameters
  include DiagnosticDownload

  def show
    window = report_window(unit: "day")
    return render_error(:window_invalid, t("usage_analysis.errors.window_invalid"), status: :bad_request) if window.invalid_parameter

    filters = admin_analysis_filters
    result = ModelUsageRollups::Analysis.call(account: Current.account,
      from: window.from, to: window.to, filters: filters, **analysis_options)
    if result.outcome == :reported
      download_diagnostics(ModelUsageRollups::Export.new(account: Current.account,
        report: result.report, filters: filters), filename: "account-model-usage.jsonl.gz")
    else
      render_error(result.refusal, t("usage_analysis.errors.#{result.refusal}"), status: :bad_request)
    end
  end
end
