module AgentLoopNodes
  # The barrier: `all` waits for every dependency to settle, `any` completes
  # on the first success and starves when none arrives, `quorum` needs
  # `quorum_k`. Joins settle inside the release walk — structural, not executed.
  class JoinTask < AgentLoopNode
    attr_readonly :provider_id, :model_ref, :reasoning_effort

    JOIN_MODES = %w[all any quorum].freeze
    # What happens to the branches that did not answer a race: `run_out` lets
    # them finish, `cancel_losers` stops them when the join settles.
    LOSER_POLICIES = %w[run_out cancel_losers].freeze
    # `all` waits for everyone, so it HAS no losers — a policy there is a
    # typo'd intent, refused at compile rather than silently ignored.
    RACING_MODES = %w[any quorum].freeze

    self.task_kind = "join_task"

    # A join never runs: it is born `queued` and settles structurally — in
    # the append door as it is born, or in the release walk — so no started
    # word, park, approval stage or `skipped`, and no birth past `queued`.
    self.transitions = {
      nil => %w[queued],
      "queued" => %w[completed failed canceled],
      "completed" => [], "failed" => [], "canceled" => [],
    }.freeze

    def race? = RACING_MODES.include?(join_mode)

    # `all` has no losers, so only a racing mode that has settled — won
    # or starved — absorbs a member's later failure.
    def settled_race? = race? && terminal?

    # The answer set is captured when the barrier settles — a failed race
    # captures what answered before it failed. A run-out branch that
    # answers later does not retroactively win the race.
    def winning_source_keys
      output_summary.fetch("outcomes", {}).filter_map do |key, outcome|
        key if outcome == "completed"
      end
    end

    validates :join_mode, inclusion: { in: JOIN_MODES }
    validates :quorum_k, numericality: { only_integer: true, greater_than: 0 },
      if: -> { join_mode == "quorum" }
    validates :quorum_k, absence: true, unless: -> { join_mode == "quorum" }
    validates :loser_policy, inclusion: { in: LOSER_POLICIES }, allow_nil: true
  end
end
