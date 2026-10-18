module ModelUsageRollups
  class Analysis
    GROUPS = UsageReport::FILTER_COLUMNS
    RANKS = %w[request_count total_tokens cost_amount].freeze
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 50
    MAX_WINDOW = 90.days
    COUNTERS = (Counters::COLUMNS + [:amount_sample_count]).freeze

    Latency = Data.define(:duration_ms, :time_to_first_token_ms)
    Group = Data.define(:value, :totals)
    Breakdown = Data.define(:group_by, :rank_by, :limit, :total_group_count, :groups, :other)
    Usage = Data.define(:totals, :status_counts, :latency, :breakdown)
    Snapshot = Data.define(:from, :to, :as_of, :cost_unit, :model_usage)
    Result = Data.define(:outcome, :refusal, :report) do
      def self.refused(refusal) = new(outcome: :refused, refusal:, report: nil)
      def self.reported(report) = new(outcome: :reported, refusal: nil, report:)
    end

    def self.call(...) = new(...).call

    def initialize(account:, from:, to:, group_by: "provider_id", rank_by: "request_count", limit: DEFAULT_LIMIT,
      conversations: nil, consumer: nil, filters: {})
      @account = account
      @from = from
      @to = to
      @group_by = group_by
      @rank_by = rank_by
      @limit = limit
      @conversations = conversations
      @consumer = consumer
      @filters = filters
    end

    def call
      refusal = query_refusal
      return Result.refused(refusal) if refusal

      ConsistentRead.call do
        @receipts = receipts
        Result.reported(Snapshot.new(
          from: @from, to: @to, as_of: Time.current, cost_unit: @account.cost_unit,
          model_usage: usage
        ))
      end
    end

    private

      def query_refusal
        return :window_invalid unless @from < @to
        return :window_too_wide if @to - @from > MAX_WINDOW
        return :filter_unsupported unless (@filters.keys - GROUPS).empty?
        return :filter_invalid unless GROUPS.include?(@group_by) && RANKS.include?(@rank_by) && (1..MAX_LIMIT).cover?(@limit)

        nil
      end

      def receipts
        scope = if @conversations
          UsageRecord.for_conversations(account: @account, conversations: @conversations, consumer: @consumer)
        else
          UsageRecord.where(account_id: @account.id)
        end
        scope.where(recorded_at: @from...@to).where(@filters)
      end

      def usage
        values = @receipts.pick(
          *counter_selections,
          *Percentiles.selections(UsageRecord.arel_table[:duration_ms]),
          *Percentiles.selections(UsageRecord.arel_table[:time_to_first_token_ms]),
          UsageRecord.arel_table[@group_by].count(true)
        )
        counters = COUNTERS.zip(values.shift(COUNTERS.length)).to_h
        count = counters.fetch(:request_count)
        latency = Latency.new(
          duration_ms: Percentiles.sample(values.shift(3), total: count),
          time_to_first_token_ms: Percentiles.sample(values.shift(3), total: count)
        )
        counts = @receipts.group(:status).count
        Usage.new(
          totals: render_counters(counters),
          status_counts: UsageRecord::STATUSES.index_with { |status| counts.fetch(status, 0) },
          latency:, breakdown: breakdown(counters, total_group_count: values.fetch(0))
        )
      end

      def counter_selections
        [*Counters.selections, Arel.sql("COUNT(cost_amount)")]
      end

      def breakdown(totals, total_group_count:)
        table = UsageRecord.arel_table
        rank = @rank_by == "request_count" ? Arel.star.count : table.coalesce(table[@rank_by].sum, 0)
        rows = @receipts.group(@group_by)
          .order(rank.desc, table[@group_by].asc)
          .limit(@limit).pluck(@group_by, *counter_selections)
        other = totals.dup
        groups = rows.map do |value, *values|
          counters = COUNTERS.zip(values).to_h
          COUNTERS.each { |column| other[column] -= counters.fetch(column) }
          Group.new(value:, totals: render_counters(counters))
        end
        Breakdown.new(
          group_by: @group_by, rank_by: @rank_by, limit: @limit,
          total_group_count:, groups:, other: render_counters(other)
        )
      end

      def render_counters(counters)
        Counters.render(counters).merge("amount_sample_count" => counters.fetch(:amount_sample_count).to_i)
      end
  end
end
