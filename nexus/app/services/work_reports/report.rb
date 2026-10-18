module WorkReports
  # Current visibility governs both retained work and its attributed usage.
  # SQL aggregates the rows; Ruby combines only the bounded time buckets.
  class Report
    UNITS = %w[hour day].freeze
    CREATED_BUCKETS = {
      "hour" => Arel.sql("DATE_TRUNC('hour', runs.created_at)"),
      "day" => Arel.sql("DATE_TRUNC('day', runs.created_at)"),
    }.freeze

    Current = Data.define(:run_counts, :attention_count)
    Totals = Data.define(:created_runs, :active_answering_agents, :conversation_usage)
    Point = Data.define(:bucket_start_at, :created_runs, :active_answering_agents, :conversation_usage)
    Previous = Data.define(:from, :to, :totals)
    Snapshot = Data.define(:from, :to, :unit, :as_of, :workspace_public_id, :agent_public_id, :current, :totals, :series, :previous)
    Result = Data.define(:outcome, :refusal, :report) do
      def self.refused(refusal) = new(outcome: :refused, refusal:, report: nil)
      def self.reported(report) = new(outcome: :reported, refusal: nil, report:)
    end

    def self.call(...) = new(...).call

    def initialize(user:, from:, to:, unit:, workspace: nil, agent: nil)
      @user = user
      @from = from
      @to = to
      @unit = unit
      @workspace = workspace
      @agent = agent
      @as_of = Time.current
    end

    def call
      return Result.refused(:unit_unsupported) unless UNITS.include?(@unit)

      @conversations = Conversation.visible_to(@user, workspace: @workspace)
      usage = usage_for(@from, @to)
      if usage.outcome == :refused
        Result.refused(usage.refusal)
      else
        @runs = Run.visible_to(@user, workspace: @workspace)
        @runs = @runs.for_agent(@agent.public_id) if @agent
        Result.reported(snapshot(usage))
      end
    end

    private

      def usage_for(from, to)
        ModelUsageRollups::UsageReport.call(
          account: @user.account, from:, to:, unit: @unit, conversations: @conversations, consumer: @agent
        )
      end

      def snapshot(usage)
        cohort = @runs.where(created_at: @from...@to)
        bucket = CREATED_BUCKETS.fetch(@unit)
        created_counts = bucket_counts(cohort.group(bucket).count)
        answerer_counts = bucket_counts(answering_runs(cohort).group(bucket).distinct.count("turns.answering_user_id"))
        series = usage.series.map do |point|
          time = point.fetch("bucket_start_at")
          Point.new(
            bucket_start_at: time,
            created_runs: created_counts.fetch(time, 0),
            active_answering_agents: answerer_counts.fetch(time, 0),
            conversation_usage: point.except("bucket_start_at")
          )
        end
        Snapshot.new(
          from: @from, to: @to, unit: @unit, as_of: @as_of,
          workspace_public_id: @workspace&.public_id,
          agent_public_id: @agent&.public_id,
          current: current_counts,
          totals: Totals.new(
            created_runs: created_counts.values.sum,
            active_answering_agents: answering_runs(cohort).distinct.count("turns.answering_user_id"),
            conversation_usage: usage.totals
          ),
          series:, previous: previous_period
        )
      end

      def bucket_counts(rows)
        rows.transform_keys { |time| time.in_time_zone("UTC").iso8601 }
      end

      # A standalone creator is not a conversation answerer. The frozen
      # Turn association also keeps historical handoffs attributed correctly.
      def answering_runs(scope)
        scope.joins(variant: { turn: :answering_user }).where(users: { kind: "agent" })
      end

      def current_counts
        counts = @runs.group(:status).count
        Current.new(
          run_counts: Run::STATUSES.index_with { |status| counts.fetch(status, 0) },
          attention_count: @runs.where.not(attention_reason: nil).count
        )
      end

      def previous_period
        previous_from = @from - (@to - @from)
        usage = usage_for(previous_from, @from)
        cohort = @runs.where(created_at: previous_from...@from)
        Previous.new(
          from: previous_from, to: @from,
          totals: Totals.new(
            created_runs: cohort.count,
            active_answering_agents: answering_runs(cohort).distinct.count("turns.answering_user_id"),
            conversation_usage: usage.totals
          )
        )
      end
  end
end
