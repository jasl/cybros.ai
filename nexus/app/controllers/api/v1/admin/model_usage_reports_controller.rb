# The statistics consumer: account-wide usage series and totals over the
# rollup buckets plus the unrolled remainder. Statistics, never money —
# budgets and settlement read receipts only.
class API::V1::Admin::ModelUsageReportsController < API::V1::Admin::BaseController
  def show
    from, to = params.expect(:from, :to)
    result = ModelUsageRollups::UsageReport.call(
      account: Current.account,
      from: parse_time(from, :from),
      to: parse_time(to, :to),
      unit: params.fetch(:unit, "hour"),
      **filter_params
    )
    render_report_result(result)
  end

  private

    # Everything besides the window reaches the service, where an unknown
    # filter key is a typed refusal; a permit() here would silently answer account-wide.
    def filter_params
      request.query_parameters.except("from", "to", "unit").to_hash
    end

    def render_report_result(result)
      case result.outcome
      when :reported
        render json: {
          report: {
            unit: params.fetch(:unit, "hour"),
            series: result.series,
            totals: result.totals,
          },
        }
      when :refused
        render_refusal(result.refusal, "Report refused: #{result.refusal}")
      else
        raise "unmapped report outcome: #{result.outcome}"
      end
    end
end
