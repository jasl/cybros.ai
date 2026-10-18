module WorkReports
  class Analysis
    Latency = Data.define(:delivery_ms, :completion_ms)
    ToolGroup = Data.define(:tool_name, :task_count, :status_counts, :error_result_count, :latency)
    Tools = Data.define(:task_count, :status_counts, :error_result_count, :latency, :total_group_count, :groups, :other_task_count)
    Execution = Data.define(
      :run_count, :retained_run_count, :details_pruned_run_count, :status_counts,
      :delivered_count, :undelivered_count, :completed_count, :uncompleted_count, :latency, :tools
    )
    Snapshot = Data.define(:from, :to, :as_of, :cost_unit, :workspace_public_id, :agent_public_id, :model_usage, :execution)

    def self.call(...) = new(...).call

    def initialize(user:, from:, to:, workspace: nil, agent: nil, **options)
      @user = user
      @from = from
      @to = to
      @workspace = workspace
      @agent = agent
      @options = options
    end

    def call
      ModelUsageRollups::ConsistentRead.call do
        usage = ModelUsageRollups::Analysis.call(
          account: @user.account, from: @from, to: @to,
          conversations: Conversation.visible_to(@user, workspace: @workspace), consumer: @agent,
          **@options
        )
        if usage.outcome == :refused
          Report::Result.refused(usage.refusal)
        else
          @runs = Run.visible_to(@user, workspace: @workspace).where(created_at: @from...@to)
          @runs = @runs.for_agent(@agent.public_id) if @agent
          Report::Result.reported(Snapshot.new(
            **usage.report.to_h, workspace_public_id: @workspace&.public_id,
            agent_public_id: @agent&.public_id, execution: execution
          ))
        end
      end
    end

    private

      # Whole elapsed milliseconds are floored before taking nearest-rank
      # percentiles. A missing endpoint is a missing sample; zero is valid.
      def elapsed_ms(finish, start)
        Arel.sql("FLOOR(EXTRACT(EPOCH FROM (? - ?)) * 1000)::bigint", finish, start)
      end

      def execution
        table = Run.arel_table
        total, pruned, delivered, completed, *latencies = @runs.pick(
          Arel.sql("COUNT(*)"), Arel.sql("COUNT(details_pruned_at)"),
          Arel.sql("COUNT(delivered_at)"), Arel.sql("COUNT(completed_at)"),
          *ModelUsageRollups::Percentiles.selections(elapsed_ms(table[:delivered_at], table[:created_at])),
          *ModelUsageRollups::Percentiles.selections(elapsed_ms(table[:completed_at], table[:created_at]))
        )
        counts = @runs.group(:status).count
        Execution.new(
          run_count: total, retained_run_count: total - pruned, details_pruned_run_count: pruned,
          status_counts: Run::STATUSES.index_with { |status| counts.fetch(status, 0) },
          delivered_count: delivered, undelivered_count: total - delivered,
          completed_count: completed, uncompleted_count: total - completed,
          latency: Latency.new(
            delivery_ms: ModelUsageRollups::Percentiles.sample(latencies.first(3), total:),
            completion_ms: ModelUsageRollups::Percentiles.sample(latencies.last(3), total:)
          ),
          tools: tools
        )
      end

      def tools
        # The correlated Run scope carries current ACLs without materializing
        # an unbounded list of Run ids. Task rows are the current retry generation.
        cohort = @runs.where("runs.id = tasks.run_id")
        scope = Tasks::ToolTask.where(cohort.arel.exists)
        total = tool_group(nil, scope.pick(*tool_selections))
        limit = @options.fetch(:limit, ModelUsageRollups::Analysis::DEFAULT_LIMIT)
        groups = scope.group(:tool_name).order(Arel.sql("COUNT(*) DESC, tool_name ASC"))
          .limit(limit).pluck(:tool_name, *tool_selections)
          .map { |name, *values| tool_group(name, values) }
        Tools.new(
          **total.to_h.except(:tool_name), total_group_count: scope.distinct.count(:tool_name), groups:,
          other_task_count: total.task_count - groups.sum(&:task_count)
        )
      end

      def tool_selections
        table = Task.arel_table
        [
          Arel.sql("COUNT(*)"),
          *Task::STATUSES.map { |status| Arel.sql("COUNT(*) FILTER (WHERE status = ?)", status) },
          Arel.sql("COUNT(*) FILTER (WHERE status = 'completed' AND output_summary @> '{\"is_error\": true}')"),
          *ModelUsageRollups::Percentiles.selections(elapsed_ms(table[:completed_at], table[:started_at])),
        ]
      end

      def tool_group(name, values)
        count = values.shift
        statuses = Task::STATUSES.zip(values.shift(Task::STATUSES.length)).to_h
        errors = values.shift
        ToolGroup.new(
          tool_name: name, task_count: count, status_counts: statuses, error_result_count: errors,
          latency: ModelUsageRollups::Percentiles.sample(values, total: count)
        )
      end
  end
end
