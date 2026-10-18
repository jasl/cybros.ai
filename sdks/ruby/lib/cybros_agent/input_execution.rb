module CybrosAgent
  # Read one accepted input's execution, keeping its original identity even
  # after another input or a manual regeneration owns the displayed turn.
  # Polling, deadlines, persistence and decisions remain the application's;
  # ending observation never cancels the underlying work.
  class InputExecution
    Snapshot = Data.define(:execution, :variant, :status, :run_status, :attention,
      :failure_reason, :failure_reason_key, :content) do
      def terminal?
        Api::TURN_TERMINAL_STATUSES.include?(status) &&
          (status != "failed" || execution.run_public_id.nil? || Api::RUN_TERMINAL_STATUSES.include?(run_status))
      end

      # The Run's failure hold. A running Run can separately carry an ask
      # or approval in attention; decisions reads those pending tasks.
      def needs_attention? = run_status == "needs_attention"
    end

    # Rejoin a known execution, such as a retried Run, without requiring an
    # input receipt. A known Run is enough when its variant is not yet known.
    def self.for_execution(execution:, replay:, variants:, run:, decisions: nil, position: KernelFeed::Position.start)
      new(execution:, replay:, variants:, run:, decisions:, position:)
    end

    attr_reader :snapshot

    def initialize(replay:, variants:, run:, input_public_id: nil, materialization: nil,
                   execution: nil, decisions: nil, position: KernelFeed::Position.start)
      if input_public_id.nil? == execution.nil?
        raise ArgumentError, "provide input_public_id or execution, exactly one"
      end
      if execution && (execution.turn.nil? || (execution.variant.nil? && execution.run_public_id.nil?))
        raise ArgumentError, "execution requires a turn and its variant or run_public_id"
      end
      if input_public_id && materialization.nil?
        raise ArgumentError, "provide a materialization callback for an input"
      end

      @replay = replay
      @variants = variants
      @run = run
      @decisions = decisions
      @initial_position = position
      @execution = execution
      @snapshot = nil
      @materialization = if input_public_id
        InputMaterialization.new(input_public_id:, replay:, position:,
          recover: ->(input) { InputMaterialization::Result.from_materialization(materialization.call(input)) })
      end
    end

    # This is the original correlation, never replaced by a later fallback.
    def result = @materialization ? @materialization.result : @execution
    def blocked_reason = @materialization&.blocked_reason
    def compaction = @materialization&.compaction
    def position = @materialization ? @materialization.position : @initial_position

    # A lightweight materialization poll: no deck, Run or decision reads.
    def refresh
      @materialization&.refresh
      self
    end

    # Explicit recovery reads the current durable candidate and Run. Retained
    # events supplement failure details, but old lifecycle notes cannot hide
    # completion or replace the original with an active manual regeneration.
    # These reads are observations, not an atomic server snapshot.
    def recover
      refresh if result.nil?
      return nil if result.nil?

      original = result
      variant = recovery_variant(@variants.call(original.turn), original)
      execution = if variant
        InputMaterialization::Result.new(turn: original.turn, variant: variant.public_id, run_public_id: variant.run_public_id)
      else
        original
      end
      state = recovery_state(execution)
      if execution.variant.nil? && state["variant_public_id"]
        execution = execution.with(variant: state.fetch("variant_public_id"))
      end
      run = @run.call(execution.run_public_id) if execution.run_public_id
      status = variant ? variant.status : state["status"]
      if status == "failed"
        failure_reason = run&.failure_reason || state["failure_reason"]
        failure_reason_key = run.turn.failure_reason_key if run&.turn&.failed?
        failure_reason_key ||= state["failure_reason_key"]
      end
      @snapshot = Snapshot.new(execution:, variant:, status:, run_status: run&.status,
        attention: run&.attention, failure_reason:, failure_reason_key:, content: variant&.content)
    end

    # Questions and approvals are read only when requested. An adapter that
    # cannot provide the member decision surface must say so, not report an
    # empty decision list for a Run it has not inspected.
    def decisions
      refresh if result.nil?
      execution = @snapshot&.execution || result
      return [] if execution.nil? || execution.run_public_id.nil?

      raise ArgumentError, "provide a decisions callback to read this run's decisions" if @decisions.nil?

      @decisions.call(execution.run_public_id)
    end

    private

      def recovery_variant(deck, original)
        candidate = if original.variant
          deck.find { |entry| entry.public_id == original.variant }
        else
          deck.find { |entry| entry.run_public_id == original.run_public_id }
        end
        variant_id = original.variant || candidate&.public_id
        if variant_id
          while (fallback = deck.find { |entry| entry.source == "fallback" && entry.origin_variant_public_id == variant_id })
            candidate = fallback
            variant_id = fallback.public_id
          end
        end
        candidate
      end

      def recovery_state(execution)
        state = {}
        KernelFeed.new(replay: @replay, position: @initial_position).each do |event|
          payload = event.payload
          next unless %w[turn_status turn_created].include?(event.type)
          next unless payload["turn_public_id"] == execution.turn
          next if execution.run_public_id && payload["run_public_id"] != execution.run_public_id
          next if execution.variant && payload["variant_public_id"] != execution.variant

          state.merge!(payload)
          # Some lifecycle writers carry only status. Read each transition
          # independently; an old variant_status cannot override a newer
          # status, and a Run-only note cannot invent a turn transition.
          status = payload["variant_status"] || payload["status"]
          if status
            state["status"] = status
            if status != "failed"
              state.delete("failure_reason")
              state.delete("failure_reason_key")
            end
          end
        end
        state
      end
  end
end
