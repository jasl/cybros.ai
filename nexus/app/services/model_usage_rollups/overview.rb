module ModelUsageRollups
  # The overview composes the same bounded public report for its comparison
  # and disposition breakdown; it owns no second metering calculation.
  class Overview
    Result = Data.define(:outcome, :refusal, :report, :previous, :status_counts) do
      def self.refused(refusal) = new(outcome: :refused, refusal:, report: nil, previous: nil, status_counts: nil)
      def self.reported(report:, previous:, status_counts:)
        new(outcome: :reported, refusal: nil, report:, previous:, status_counts:)
      end
    end

    def self.call(...) = new(...).call

    def initialize(account:, from:, to:, unit:, **filters)
      @account = account
      @from = from
      @to = to
      @unit = unit
      @filters = filters
    end

    def call
      ConsistentRead.call { report_result }
    end

    private

      # A receipt arriving between the total and status reads must not make
      # a disposition count exceed the denominator displayed beside it.
      def report_result
        report = usage_for(@from, @to)
        if report.outcome == :refused
          Result.refused(report.refusal)
        else
          Result.reported(
            report:, previous: usage_for(previous_from, @from),
            status_counts: status_counts(report)
          )
        end
      end

      def usage_for(from, to, **filters)
        UsageReport.call(account: @account, from:, to:, unit: @unit, **@filters, **filters)
      end

      def previous_from
        if @unit == "month"
          months = (@to.year - @from.year) * 12 + @to.month - @from.month
          @from.advance(months: -months)
        else
          @from - (@to - @from)
        end
      end

      def status_counts(report)
        UsageRecord::STATUSES.index_with do |status|
          if @filters.key?("status")
            @filters.fetch("status") == status ? report.totals.fetch("request_count") : 0
          else
            usage_for(@from, @to, "status" => status).totals.fetch("request_count")
          end
        end
      end
  end
end
