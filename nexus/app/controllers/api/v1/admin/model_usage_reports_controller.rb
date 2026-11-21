# The statistics consumer: account-wide usage series and totals over the
# rollup buckets plus the unrolled remainder. Statistics, never money —
# budgets and settlement read receipts only.
# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelUsageReportsController < API::V1::Admin::BaseController
  # @oas_include
  # @summary Read model usage reports
  # @tags Platform, model usage reports
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelUsageReportsShow
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
