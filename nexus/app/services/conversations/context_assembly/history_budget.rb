module Conversations
  class ContextAssembly
    # The share mapping in one place, so the estimate and the drain cannot
    # drift. A share against a windowless model refuses: silence would
    # unbound exactly what the caller asked to bound.
    module HistoryBudget
      module_function

      def call(share:, limits:)
        return Outcome.accepted(nil) if share.nil?

        window = limits.planning_input_bound
        return Outcome.refused(:history_budget_unavailable) if window.nil?

        Outcome.accepted((window * share.to_f).floor)
      end
    end
  end
end
