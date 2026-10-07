module AgentRuns
  # The one formula for "does this dependency satisfy" — append-time,
  # the release walk and adjudication recounts all call here, because three
  # hand-written copies drifting apart was the predecessor's top wedge source.
  module Graph
    module_function

    # `race_settled` is the one fact the row's own columns cannot carry — the
    # node lost a race that already has its answer (`settled_race_loser?`).
    # "Resolved without adjudication" has ONE derived branch here: the policy
    # `absorb`, or that settled race — never a persisted stamp (`absorbed` was
    # a stored copy of this line).
    def settlement(status:, on_failure:, failure_resolution:, race_settled: false)
      case status
      when "completed" then :success
      when "skipped" then :skip
      # A join loser or a stopped loop's cancel skips; a person's branch
      # cancel RESOLVES: the blocking consumer runs and reads
      # `status="canceled"` in its envelope.
      when "canceled" then failure_resolution.present? ? :resolved : :skip
      when *AgentRunTask::FAILURE_STATUSES
        return :resolved if failure_resolution.present? || on_failure == "absorb" || race_settled
        return :skip if on_failure == "propagate"

        :pending
      else :pending
      end
    end

    # The node's own three columns, plus the one edge fact the formula
    # cannot see: a loser of a race that already settled is absorbed by
    # that settlement — the question it was racing to answer has an
    # answer, so its later halt-failure is no hold. The value is
    # `:resolved`, "satisfied, not success", never a new word.
    def settlement_of(node)
      settlement(
        status: node.status,
        on_failure: node.on_failure,
        failure_resolution: node.failure_resolution,
        race_settled: settled_race_loser?(node)
      )
    end

    # Only a halt-failure needs the edge read: propagate already skips and
    # absorb already resolves. Every consumer must be a terminal racing
    # join or a task canceled as part of that losing branch. A live plain
    # consumer or open race still needs adjudication. The association is
    # read as loaded, so a caller that walks many rows preloads it and stays flat.
    def settled_race_loser?(node)
      return false unless AgentRunTask::FAILURE_STATUSES.include?(node.status)
      return false if node.failure_resolution.present? || node.on_failure != "halt"

      consumers = node.outgoing_edges.map(&:to_node)
      consumers.any? && consumers.all? do |consumer|
        consumer.settled_race? ||
          (consumer.status == "canceled" && consumer.error_key == CancelLosers::REASON)
      end
    end

    # A non-join head is BORN SKIPPED when any source already skipped —
    # the transitive cascade, applied at construction time (edges only
    # ever point at batch-new heads, so append order is settlement order).
    def skip_at_birth?(join_mode, settlements)
      join_mode.nil? && settlements.any? { |s| s == :skip }
    end

    # The countdown a freshly created head starts at, given its sources'
    # settlements. Joins count by their mode; plain nodes count pending
    # sources (:success and :resolved both satisfy).
    def initial_countdown(join_mode, quorum_k, settlements)
      case join_mode
      when "all" then settlements.count(:pending)
      when "any" then settlements.any? { |s| s == :success } ? 0 : 1
      when "quorum"
        (quorum_k - settlements.count(:success)).clamp(0..)
      else settlements.count(:pending)
      end
    end

    # A join whose remaining sources can no longer produce what it needs
    # fails now rather than hanging.
    def join_failure(join_mode, quorum_k, settlements)
      case join_mode
      when "any"
        "join_starved" if settlements.none?(:pending) && settlements.none?(:success)
      when "quorum"
        if settlements.count(:success) + settlements.count(:pending) < quorum_k
          "quorum_unreachable"
        end
      else nil
      end
    end

    # The summary renders verbatim as the task's result, so a pending source
    # speaks the trace vocabulary — `waiting`, never the engine's `queued`;
    # a failure resolved by its policy or its race reads `absorbed`, the
    # word the summary always carried for it.
    def join_outcomes(sources_by_key)
      sources_by_key.transform_values do |node|
        case settlement_of(node)
        when :success then "completed"
        when :skip then node.status == "canceled" ? "canceled" : "skipped"
        when :resolved then node.failure_resolution || "absorbed"
        else node.status == "queued" ? "waiting" : node.status
        end
      end
    end
  end
end
