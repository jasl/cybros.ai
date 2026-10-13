module AgentRuns
  module SourceWork
    # A source hint visits only that owner's requests. Independent input/turn
    # pages charge retained rows before inspecting their execution. Completed
    # owners still forward the hint; the existing sweeps recover lost hints.
    class Recovery
      BUDGET = 200

      def self.call(...) = new(...).call

      def initialize(source_run_public_id:, input_after_id: 0, turn_after_id: 0,
                     inputs_done: false, turns_done: false, budget: BUDGET)
        @source_run_public_id = source_run_public_id
        @input_after_id, @turn_after_id = input_after_id.to_i, turn_after_id.to_i
        @inputs_done, @turns_done, @budget = inputs_done, turns_done, budget
      end

      def call
        inputs = window(ConversationInput, @input_after_id, @inputs_done)
        turns = window(ConversationTurn, @turn_after_id, @turns_done)
        canceled = inputs.sum { |id| recover(:input, id) { self.class.input(id) ? 1 : 0 } }
        source = AgentRun.find_by(public_id: @source_run_public_id)
        if SourceWork.stopped?(@source_run_public_id, source)
          canceled += turns.sum { |id| recover(:turn, id) { recover_turn(id) } }
        end
        Sweeps::Pass.new(
          counts: { canceled: canceled, scanned: inputs.length + turns.length },
          cursor: {
            "source_run_public_id" => @source_run_public_id,
            "input_after_id" => inputs.last || @input_after_id,
            "turn_after_id" => turns.last || @turn_after_id,
            "inputs_done" => inputs.length < @budget, "turns_done" => turns.length < @budget,
          },
          more: @budget.positive? && (inputs.length == @budget || turns.length == @budget)
        )
      end

      def self.input(id)
        input = ConversationInput.find_by(id: id)
        return false unless input

        input.host.with_lock do
          SourceWork.with_source(input.sender_run_public_id) do |source|
            next false unless SourceWork.stopped?(input.sender_run_public_id, source)

            input = input.host.conversation_inputs.lock.find_by(id: id)
            next false unless input

            Conversations::Inputs::Destroy.remove(input)
            input.host.wake_drain
            true
          end
        end
      end

      def self.variant(id)
        variant = ConversationTurnVariant.find_by(id: id)
        return false unless variant&.model_invocation_id

        conversation = variant.conversation_turn.conversation
        conversation.with_lock do
          variant.reload
          next false unless ConversationTurnVariant::ACTIVE_STATUSES.include?(variant.status)

          public_id = SourceWork.source_of(variant)
          SourceWork.with_source(public_id) do |source|
            next false unless SourceWork.stopped?(public_id, source)

            invocation = variant.model_invocation
            invocation.with_lock do
              invocation.terminalize(status: "canceled", reason_key: "source_stopped") unless invocation.terminal?
              Conversations::Turns::Converge.settle_now(conversation, invocation, variant)
            end
            true
          end
        end
      end

      private

        def recover(kind, id)
          yield
        rescue StandardError => error
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "source_work_recovery_failed", source_kind: kind, source_id: id })
          0
        end

        def window(model, after_id, done)
          return [] if done || !@budget.positive?

          model.where(sender_run_public_id: @source_run_public_id)
            .where(id: (after_id + 1)..).order(:id).limit(@budget).pluck(:id)
        end

        def recover_turn(id)
          turn = ConversationTurn.find_by(id: id)
          return 0 unless turn && !turn.forked_from_turn_public_id

          original = turn.conversation_turn_variants.find_by(position: 0)
          return 0 unless original

          # Human replacements own themselves. The original and its one kernel
          # fallback inherit the source, even after completion or concealment.
          variants = [original] + turn.conversation_turn_variants
            .where(source: "fallback", origin_variant_id: original.id).to_a
          variants.count do |variant|
            agent_run = variant.agent_run
            if agent_run
              ScheduleReady.call(agent_run_id: agent_run.id) unless agent_run.terminal?
              Spawn::RelayJob.perform_later(nil, { "source_run_public_id" => agent_run.public_id })
              agent_run.reload.stopped?
            else
              self.class.variant(variant.id)
            end
          end
        end
    end
  end
end
