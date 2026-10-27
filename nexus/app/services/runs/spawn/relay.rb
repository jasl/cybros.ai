module Runs
  module Spawn
    # Request completions converge through their existing Task frontier. A
    # child hint accelerates its original spawn, while scheduled occurrences
    # retain their one original reply relay. Input/variant windows recover
    # source Stop and closed-link cleanup independently of either result lane.
    class Relay
      BUDGET = 200
      OWED_KINDS = { kind: "direct_reply", role: "assistant" }.freeze

      def self.call(...) = new(...).call

      # Guarded, never locked (`turns` is off the ladder):
      # the marker is not a status, and both paths write it once.
      def self.stamp(turn) = turn.stamp_relayed

      def initialize(conversation_id: nil, after_id: 0, delegation_after_id: 0,
                     children_done: false, delegations_done: false, budget: BUDGET,
                     input_after_id: 0, variant_after_id: 0, inputs_done: false, variants_done: false)
        @conversation_id = conversation_id
        @after_id = after_id.to_i
        @delegation_after_id = delegation_after_id.to_i
        @children_done, @delegations_done = children_done, delegations_done
        @budget = budget
        @input_after_id, @variant_after_id = input_after_id, variant_after_id
        @inputs_done, @variants_done = inputs_done, variants_done
      end

      def call
        children = frontier
        relayed = children.sum { |child_id| relay_child(child_id) }
        delegated = delegation_frontier
        completed = delegated.count { |node| converge_delegation(node) }
        inputs = source_window(Input.where.not(sender_run_public_id: nil),
          @input_after_id, @inputs_done)
        variants = source_window(Variant.where(deleted_at: nil,
          status: Variant::ACTIVE_STATUSES + ["failed"]), @variant_after_id, @variants_done)
        canceled = inputs.count { |id| recover_source(:input, id) } + variants.count { |id| recover_source(:variant, id) }
        more_children = !@conversation_id && !@children_done && children.length == @budget
        more_delegations = !@conversation_id && !@delegations_done && @delegation_ids.length == @budget
        Sweeps::Pass.new(
          counts: { relayed: relayed + completed, canceled: canceled,
                    scanned: children.length + @delegation_ids.length + inputs.length + variants.length },
          cursor: {
            "after_id" => children.last || @after_id,
            "delegation_after_id" => @delegation_ids.last || @delegation_after_id,
            "children_done" => !more_children, "delegations_done" => !more_delegations,
            "input_after_id" => inputs.last || @input_after_id,
            "variant_after_id" => variants.last || @variant_after_id,
            "inputs_done" => inputs.length < @budget, "variants_done" => variants.length < @budget,
          },
          more: more_children || more_delegations || inputs.length == @budget || variants.length == @budget
        )
      end

      private

        def source_window(scope, after_id, done)
          return [] if @conversation_id || done || !@budget.positive?

          scope.where(id: (after_id + 1)..).order(:id).limit(@budget).pluck(:id)
        end

        def recover_source(kind, id)
          SourceWork::Recovery.public_send(kind, id)
        rescue StandardError => error
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "source_work_recovery_failed", source_kind: kind, source_id: id })
          false
        end

        # Lock-free scheduled-occurrence window; one child when a kick names it.
        def frontier
          return [] if @children_done

          return Conversation.where(id: @conversation_id).pluck(:id) if @conversation_id

          Conversation.where.not(schedule_id: nil).where(id: (@after_id + 1)..).order(:id).limit(@budget).pluck(:id)
        end

        def delegation_frontier
          @delegation_ids = []
          return [] if @conversation_id || @delegations_done

          @delegation_ids = Delegations.recovery_candidates(after_id: @delegation_after_id, limit: @budget).pluck(:id)
          Task.where(id: @delegation_ids).order(:id).to_a
        end

        def converge_delegation(node)
          Delegations.converge(node: node)
        rescue StandardError => error
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "delegation_relay_failed", run_public_id: node.run.public_id,
                       task_key: node.node_key })
          false
        end

        def relay_child(child_id)
          child = Conversation.find_by(id: child_id)
          return 0 if child.nil?

          completion = Delegations::Converge.call(child: child) if @conversation_id
          (completion ? 1 : 0) + unrelayed_replies(child).count { |turn| relay_turn(child, turn) }
        rescue StandardError => error
          # The poison-row lesson: one unrelayable child must not abort the
          # batch. Its turns stay on the frontier and the next pass retries.
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "spawn_reply_relay_failed", conversation_id: child_id })
          0
        end

        def unrelayed_replies(child)
          return [] unless child.scheduled_execution? && child.scheduled_turn_public_id

          child.turns.where(**OWED_KINDS, relayed_at: nil, public_id: child.scheduled_turn_public_id)
            .select { |turn| Schedules::Execution.ready_for_reply?(turn) }
        end

        # Only the schedule's original reply enters this lane. Spawn and
        # request outcomes are owned by their completion Task.
        def relay_turn(child, turn)
          result = ResultDelivery.scheduled_reply(child: child, turn: turn)
          return stamp(turn) if [:not_found, :source_stopped].include?(result)

          result == :delivered
        end

        def stamp(turn)
          self.class.stamp(turn)
          true
        end
    end
  end
end
