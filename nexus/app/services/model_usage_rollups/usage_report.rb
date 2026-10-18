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
    # Administration may slice infrastructure usage, never a member's work
    # or application attribution. Conversation readers pass their authorized
    # relation separately; it is not a caller-selectable reporting dimension.
    FILTER_COLUMNS = %w[provider_id catalog_model_ref workload status].freeze

    Result = Data.define(:outcome, :refusal, :series, :totals) do
      def self.refused(refusal) = new(outcome: :refused, refusal:, series: nil, totals: nil)
      def self.reported(series:, totals:) = new(outcome: :reported, refusal: nil, series:, totals:)
    end

    def self.call(...) = new(...).call

    # `**filters`: every remaining query key is a dimension filter, keyed by
    # its wire name; a non-scalar value reads nil and is refused typed.
    def initialize(account:, from:, to:, unit:, conversations: nil, consumer: nil, **filters)
      @account = account
      @from = from
      @to = to
      @unit = unit
      @conversations = conversations
      @consumer = consumer
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
        # Buckets have no Conversation dimension. A content-scoped report
        # therefore reads receipts once, including already rolled rows.
        if @conversations
          [unrolled_rows]
        else
          ConsistentRead.call do
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
        scope = if @conversations
          UsageRecord.for_conversations(account: @account, conversations: @conversations, consumer: @consumer)
        else
          UsageRecord.where(account_id: @account.id, hourly_rolled_up_at: nil)
        end
        scope
          .where(recorded_at: @from...@to)
          .where(@filters)
          .group(bucket)
          .pluck(bucket, *Counters.selections)
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
        Counters.render(counters)
      end
  end
end
