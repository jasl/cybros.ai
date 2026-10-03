module AgentLoops
  # When a racing join has its answer, `cancel_losers` stops the branches that
  # lost: a pending ancestor is a loser when every consumer of it is terminal or
  # itself a loser, which spares shared work.
  class CancelLosers
    CANCEL_LOSERS = "cancel_losers".freeze
    REASON = "join_loser_canceled".freeze
    PENDING_STATUSES = AgentLoopNode::LIVE_STATUSES

    class << self
      def call(join)
        return [] unless join.loser_policy == CANCEL_LOSERS

        losers = abandoned(join)
        # The in-flight half settles after commit: the release walk already
        # holds the event cursor, which ranks below model_invocations on the
        # lock ladder. The queued half needs no invocation and settles now.
        terminalize_after_commit(losers.filter_map { |node| running_step_id(node) })
        losers.reject { |node| running_step_id(node) }
          .map { |node| settle(node) }
      end

      private

        # The join's pending ancestor cone, narrowed to the nodes nothing
        # live is waiting for. Fixpoint rather than one pass: a diamond
        # can put a candidate before the consumer that frees it.
        def abandoned(join)
          cone = pending_cone(join)
          chosen = {}
          loop do
            fresh = cone.reject { |node| chosen.key?(node.id) }
              .select { |node| abandoned?(node, chosen) }
            break if fresh.empty?

            fresh.each { |node| chosen[node.id] = node }
          end
          chosen.values
        end

        def pending_cone(join)
          cone = {}
          frontier = pending_sources(join)
          until frontier.empty?
            node = frontier.shift
            next if cone.key?(node.id)

            cone[node.id] = node
            frontier.concat(pending_sources(node))
          end
          cone.values
        end

        def pending_sources(node)
          node.incoming_edges.where(structural: true).includes(:from_node).map(&:from_node)
            .select { |source| PENDING_STATUSES.include?(source.status) }
        end

        def abandoned?(node, chosen)
          node.outgoing_edges.includes(:to_node).map(&:to_node).all? do |consumer|
            consumer.terminal? || chosen.key?(consumer.id)
          end
        end

        def running_step_id(node)
          node.selected_model_invocation_id if node.holds_invocation?
        end

        def settle(node)
          Transition.node(node, status: "canceled", completed_at: Time.current,
            error_key: REASON)
        end

        # Outside the loop lock nothing else serializes multi-invocation
        # lockers, so ascending id is pinned here as loop cancel pins it; the
        # node settles when the converger applies the terminal.
        def terminalize_after_commit(invocation_ids)
          ids = invocation_ids.compact.uniq.sort
          return if ids.empty?

          ApplicationRecord.current_transaction.after_commit do
            ApplicationRecord.transaction do
              ModelInvocation.where(id: ids).order(:id).lock.each do |invocation|
                invocation.terminalize(status: "canceled", reason_key: REASON)
              end
            end
            ConvergeTerminalStepsJob.perform_later
          end
        end
    end
  end
end
