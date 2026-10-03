module ModelUsageRollups
  # Answers are exact: rolled/unrolled is a clean partition, so buckets in
  # window plus the unrolled remainder equals raw truth for any aligned
  # window; an unaligned one is refused rather than approximated.
  class UsageReport
    UNITS = %w[hour day month].freeze
    UNROLLED_BUCKETS = {
      "hour" => Arel.sql("DATE_TRUNC('hour', recorded_at)"),
      "day" => Arel.sql("DATE_TRUNC('day', recorded_at)"),
      "month" => Arel.sql("DATE_TRUNC('month', recorded_at)"),
    }.freeze
    # A report is a bounded page of statistics, not an export: past this
    # many series points the window is refused, typed.
    MAX_POINTS = 1_000
    # The filterable dimensions, spelled as the wire spells them: the
    # query's own keys reach here as keywords and are judged by name.
    FILTER_COLUMNS = (ModelUsageTimeBucket::DIMENSION_COLUMNS - %i[account_id]).map(&:to_s).freeze

    Result = Data.define(:outcome, :refusal, :series, :totals) do
      def self.refused(refusal) = new(outcome: :refused, refusal:, series: nil, totals: nil)
      def self.reported(series:, totals:) = new(outcome: :reported, refusal: nil, series:, totals:)
    end

    def self.call(...) = new(...).call

    # `**filters`: every remaining query key is a dimension filter, keyed by
    # its wire name; a non-scalar value reads nil and is refused typed.
    def initialize(account:, from:, to:, unit:, **filters)
      @account = account
      @from = from
      @to = to
      @unit = unit
      @filters = filters.transform_values { |value| String.try_convert(value) }
    end

    def call
      refusal = window_refusal
      return Result.refused(refusal) if refusal

      rows = merge_rows(*partitioned_rows)
      Result.reported(series: series_for(rows), totals: totals_for(rows))
    end

    private

      COUNTERS = ModelUsageTimeBucket::COUNTER_COLUMNS

      def window_refusal
        return :unit_unsupported unless UNITS.include?(@unit)
        return :filter_unsupported unless (@filters.keys - FILTER_COLUMNS).empty?
        return :filter_invalid if @filters.values.any?(&:nil?)
        return :window_invalid unless aligned?(@from) && aligned?(@to) && @from < @to
        return :window_too_wide if points.length > MAX_POINTS

        nil
      end

      # Both reads under one snapshot, or a batch committing between them
      # vanishes from both sides. SET TRANSACTION only works at top level, so
      # a caller wrapping this must bring REPEATABLE READ itself.
      def partitioned_rows
        if UsageRecord.connection_pool.with_connection(&:transaction_open?)
          [bucket_rows, unrolled_rows]
        else
          UsageRecord.transaction(isolation: :repeatable_read) do
            [bucket_rows, unrolled_rows]
          end
        end
      end

      def aligned?(time)
        utc = time.in_time_zone("UTC")
        case @unit
        when "hour" then utc == utc.beginning_of_hour
        when "day" then utc == utc.beginning_of_day
        else utc == utc.beginning_of_month
        end
      end

      # Every unit boundary in [from, to): the series zero-fills these, so a
      # quiet hour reads as zeros instead of a hole.
      def points
        @points ||= begin
          list = []
          cursor = @from.in_time_zone("UTC")
          while cursor < @to
            list << cursor
            cursor = advance(cursor)
            break if list.length > MAX_POINTS
          end
          list
        end
      end

      def advance(cursor)
        case @unit
        when "hour" then cursor + 1.hour
        when "day" then cursor + 1.day
        else cursor + 1.month
        end
      end

      # Day series group hour buckets; hour and month series read their own
      # bucket kind directly.
      def bucket_rows
        kind = @unit == "month" ? "month" : "hour"
        scope = ModelUsageTimeBucket
          .where(account_id: @account.id, bucket_kind: kind)
          .where(bucket_start_at: @from...@to)
          .where(@filters)
        sums = COUNTERS.map { |column| "SUM(#{column})" }
        scope.group(Arel.sql(bucket_truncation))
          .pluck(Arel.sql(([bucket_truncation] + sums).join(", ")))
      end

      def bucket_truncation
        @unit == "day" ? "DATE_TRUNC('day', bucket_start_at)" : "bucket_start_at"
      end

      # The not-yet-drained remainder, straight off the receipts — same
      # counters, same completeness rule, spelled in SQL.
      def unrolled_rows
        bucket = UNROLLED_BUCKETS.fetch(@unit)
        cost_evidence_statuses = UsageRecord::COST_EVIDENCE_STATUSES
        selections = [
          bucket,
          Arel.sql("COUNT(*)"),
          Arel.sql("SUM(COALESCE(input_tokens, 0))"),
          Arel.sql("SUM(COALESCE(cache_read_tokens, 0))"),
          Arel.sql("SUM(COALESCE(cache_creation_tokens, 0))"),
          Arel.sql("SUM(COALESCE(output_tokens, 0))"),
          Arel.sql("SUM(COALESCE(reasoning_tokens, 0))"),
          Arel.sql("SUM(COALESCE(total_tokens, 0))"),
          Arel.sql("SUM(COALESCE(cost_amount, 0))"),
          Arel.sql(
            "COUNT(*) FILTER (WHERE status NOT IN (?))" \
              " + COUNT(cost_amount) FILTER (WHERE status IN (?))",
            cost_evidence_statuses,
            cost_evidence_statuses
          ),
        ]
        UsageRecord
          .where(account_id: @account.id, hourly_rolled_up_at: nil)
          .where(recorded_at: @from...@to)
          .where(@filters)
          .group(bucket)
          .pluck(*selections)
      end

      def merge_rows(*row_sets)
        merged = Hash.new { |hash, key| hash[key] = COUNTERS.index_with(0) }
        row_sets.each do |rows|
          rows.each do |time, *values|
            point = merged[time.in_time_zone("UTC")]
            COUNTERS.zip(values) { |column, value| point[column] += value }
          end
        end
        merged
      end

      def series_for(rows)
        points.map do |point|
          { "bucket_start_at" => point.iso8601 }.merge(
            render_counters(rows.fetch(point) { COUNTERS.index_with(0) })
          )
        end
      end

      def totals_for(rows)
        totals = COUNTERS.index_with(0)
        rows.each_value do |counters|
          COUNTERS.each { |column| totals[column] += counters.fetch(column) }
        end
        render_counters(totals)
      end

      # A `SUM` over bigint comes back numeric; counts are integers on the
      # wire, money is a decimal string.
      def render_counters(counters)
        {
          "request_count" => counters.fetch(:request_count).to_i,
          "input_tokens" => counters.fetch(:input_tokens).to_i,
          "cache_read_tokens" => counters.fetch(:cache_read_tokens).to_i,
          "cache_creation_tokens" => counters.fetch(:cache_creation_tokens).to_i,
          "output_tokens" => counters.fetch(:output_tokens).to_i,
          "reasoning_tokens" => counters.fetch(:reasoning_tokens).to_i,
          "total_tokens" => counters.fetch(:total_tokens).to_i,
          "cost_amount" => counters.fetch(:cost_amount).to_d.to_s("F"),
          "cost_complete" =>
            counters.fetch(:cost_known_request_count) == counters.fetch(:request_count),
        }
      end
  end
end
