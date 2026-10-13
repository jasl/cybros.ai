module Workspaces
  # The convergence sweep: one completion attempt per candidate inside the
  # budget, cursor advancing past no-progress rows so a descendant barrier
  # cannot hot-loop; the next pass rediscovers.
  class SweepTransitions
    TRANSITION_STATES = %w[archiving restoring deleting].freeze

    Result = Data.define(:outcome, :processed, :more, :cursor)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(budget:, after_id: 0)
      @budget = budget
      @after_id = after_id
    end

    def call
      processed = 0
      cursor = @after_id

      # Termination: at most budget rows, each advancing the cursor.
      candidates.each do |workspace|
        CompleteTransition.call(workspace: workspace)
        processed += 1
        cursor = workspace.id
      end

      Sweeps::Pass.new(counts: { processed: processed }, cursor: cursor, more: processed == @budget)
    end

    private

      def candidates
        Workspace.where(state: TRANSITION_STATES, id: (@after_id + 1)..).order(:id).limit(@budget)
      end
  end
end
