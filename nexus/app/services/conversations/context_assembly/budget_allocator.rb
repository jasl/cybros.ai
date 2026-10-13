module Conversations
  class ContextAssembly
    # Sizes the children of one prompt under one token pool. The reservation
    # pass runs first — required (overflow: error) children before optional
    # ones, in the order given — and only the remainder is distributed by the
    # strategy. The allocator honours the order and the priorities it is
    # handed; the trim ORDER (history before the slots) is the caller's
    # arrangement: every slot a required floor, history the optional child.
    #
    # No window → no allocator: a nil parent budget answers nil to every
    # child (never 0 — alt coerced nil to 0 and starved a windowless model),
    # and the caller's unbounded arm takes over.
    module BudgetAllocator
      STRATEGIES = %w[priority_fill proportional].freeze

      Child = Data.define(:key, :priority, :budget)

      ChildState = Data.define(
        :key,
        :priority,
        :budget,
        :weight,
        :share,
        :min_tokens,
        :reserved_tokens,
        :max_tokens,
        :allocation_cap_tokens,
        :overflow,
        :allocated_tokens,
        :excluded,
      ) do
        def reservation_request
          [min_tokens, reserved_tokens].max
        end

        def required?
          overflow == "error"
        end

        def floor_met?
          allocated_tokens >= reservation_request
        end

        def remaining_capacity
          return 0 if excluded
          return Float::INFINITY if allocation_cap_tokens.nil?

          [allocation_cap_tokens - allocated_tokens, 0].max
        end

        def allocate(tokens)
          with(allocated_tokens: allocated_tokens + [tokens, remaining_capacity].min)
        end
      end

      Allocation = Data.define(
        :key,
        :allocated_tokens,
        :requested_min_tokens,
        :requested_reserved_tokens,
        :requested_max_tokens,
        :requested_share,
        :overflow,
        :exclusion_reason,
      ) do
        def to_h
          {
            key:,
            allocated_tokens:,
            requested_min_tokens:,
            requested_reserved_tokens:,
            requested_max_tokens:,
            requested_share:,
            overflow:,
            exclusion_reason:,
          }.compact
        end
      end

      module_function

      # min_tokens is a FLOOR under every strategy: the reservation pass runs
      # first — required children before optional ones, in recipe order — and
      # only the remainder is distributed by the strategy. An unmeetable
      # floor excludes its child and RELEASES its partial funding back to
      # the pool (children excluded one at a time, refunding between rounds,
      # so a floor that becomes fundable with the freed tokens still gets
      # funded) instead of stranding the whole pool on an excluded child.
      def call(parent_budget:, strategy:, children:)
        raise ArgumentError, "unknown strategy #{strategy.inspect}" unless STRATEGIES.include?(strategy)

        return children.each_with_index.map { |child, index| unbounded_allocation(child, index) } if parent_budget.nil?

        available_tokens = non_negative_integer(parent_budget)
        states = children.each_with_index.map do |child, index|
          child_state(child, index, parent_budget: available_tokens)
        end

        states, available_tokens = fund_floors(states, available_tokens)
        states, _available_tokens =
          case strategy
          when "priority_fill"
            priority_fill(states, available_tokens)
          when "proportional"
            proportional_fill(states, available_tokens)
          else
            raise ArgumentError, "unknown strategy #{strategy.inspect}"
          end

        states.map { |state| allocation_for(state) }
      end

      def child_state(child, index, parent_budget:)
        budget = child.budget.to_h
        priority = child.priority
        share = optional_share(budget["share"])
        min_tokens = non_negative_integer(budget["min_tokens"])
        reserved_tokens = non_negative_integer(budget["reserved_tokens"])
        max_tokens = optional_non_negative_integer(budget["max_tokens"])

        ChildState.new(
          key: child_key(child, index),
          priority:,
          budget:,
          weight: positive_integer(priority, default: 1),
          share:,
          min_tokens:,
          reserved_tokens:,
          max_tokens:,
          allocation_cap_tokens: allocation_cap_tokens(parent_budget, share:, min_tokens:, reserved_tokens:, max_tokens:),
          overflow: budget["overflow"] || "block_policy",
          allocated_tokens: 0,
          excluded: false,
        )
      end

      def child_key(child, index)
        value = child.key
        return "$child_#{index}" if value.nil? || value == ""

        value
      end

      def fund_floors(states, available_tokens)
        loop do
          states, available_tokens = fund_reservations(states, available_tokens) { |state| state.required? }
          states, available_tokens = fund_reservations(states, available_tokens) { |state| !state.required? }

          unmet_index = states.index { |state| !state.excluded && !state.floor_met? }
          break if unmet_index.nil?

          unmet = states.fetch(unmet_index)
          available_tokens += unmet.allocated_tokens
          states[unmet_index] = unmet.with(allocated_tokens: 0, excluded: true)
        end

        [states, available_tokens]
      end

      def fund_reservations(states, available_tokens)
        states = states.map do |state|
          next state if state.excluded
          next state unless yield(state)

          request = [state.reservation_request - state.allocated_tokens, 0].max
          funded = [request, state.remaining_capacity, available_tokens].min
          available_tokens -= funded
          state.allocate(funded)
        end

        [states, available_tokens]
      end

      def priority_fill(states, available_tokens)
        states_by_index = states.each_with_index.sort_by { |state, index| [-state.weight, index] }
        states_by_index.each do |state, index|
          funded = [state.remaining_capacity, available_tokens].min
          next if funded.zero?

          states[index] = state.allocate(funded)
          available_tokens -= funded
          break if available_tokens.zero?
        end

        [states, available_tokens]
      end

      def proportional_fill(states, available_tokens)
        loop do
          eligible = states.each_with_index.select { |state, _index| state.remaining_capacity.positive? }
          break if available_tokens.zero? || eligible.empty?

          grants = proportional_grants(eligible, available_tokens)
          break if grants.empty?

          grants.each do |index, tokens|
            states[index] = states.fetch(index).allocate(tokens)
            available_tokens -= tokens
          end
        end

        [states, available_tokens]
      end

      # Each eligible child takes the floor of its weighted share; the
      # leftover tokens go one each to the largest fractional remainders,
      # earlier index first on a tie.
      def proportional_grants(eligible, available_tokens)
        total_weight = eligible.sum { |state, _index| state.weight }
        grants = eligible.each_with_object({}) do |(state, index), result|
          exact_share = Rational(available_tokens * state.weight, total_weight)
          result[index] = [exact_share.floor, state.remaining_capacity].min
        end

        remaining_tokens = available_tokens - grants.values.sum
        return grants.select { |_index, tokens| tokens.positive? } if remaining_tokens.zero?

        fractional_order = eligible.sort_by do |state, index|
          exact_share = Rational(available_tokens * state.weight, total_weight)
          [-(exact_share - exact_share.floor), index]
        end

        fractional_order.each do |state, index|
          break if remaining_tokens.zero?

          next unless grants.fetch(index) < state.remaining_capacity

          grants[index] += 1
          remaining_tokens -= 1
        end

        grants.select { |_index, tokens| tokens.positive? }
      end

      def allocation_for(state)
        Allocation.new(
          key: state.key,
          allocated_tokens: state.allocated_tokens,
          requested_min_tokens: state.min_tokens,
          requested_reserved_tokens: state.reserved_tokens,
          requested_max_tokens: state.max_tokens,
          requested_share: state.share,
          overflow: state.overflow,
          exclusion_reason: exclusion_reason_for(state),
        )
      end

      # The windowless answer: what was asked is echoed, nothing is sized,
      # nothing is excluded.
      def unbounded_allocation(child, index)
        state = child_state(child, index, parent_budget: 0)

        Allocation.new(
          key: state.key,
          allocated_tokens: nil,
          requested_min_tokens: state.min_tokens,
          requested_reserved_tokens: state.reserved_tokens,
          requested_max_tokens: state.max_tokens,
          requested_share: state.share,
          overflow: state.overflow,
          exclusion_reason: nil,
        )
      end

      def exclusion_reason_for(state)
        "budget_exhausted" if state.excluded || state.allocated_tokens < state.reservation_request
      end

      def non_negative_integer(value)
        [value.to_i, 0].max
      end

      def optional_non_negative_integer(value)
        return nil if value.nil?

        non_negative_integer(value)
      end

      def optional_share(value)
        return nil if value.nil?

        [[value.to_f, 0.0].max, 1.0].min
      end

      def allocation_cap_tokens(parent_budget, share:, min_tokens:, reserved_tokens:, max_tokens:)
        return max_tokens if share.nil?

        assigned = (parent_budget * share).floor
        assigned = [assigned, min_tokens, reserved_tokens].max
        return assigned if max_tokens.nil?

        [assigned, max_tokens].min
      end

      def positive_integer(value, default:)
        integer = value.to_i
        integer.positive? ? integer : default
      end
    end
  end
end
