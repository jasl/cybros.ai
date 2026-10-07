module AgentRuns
  # The live half of the one formula: a settled node recomputes every
  # queued head downstream through the same functions append-time used, so
  # release and init can never disagree. Returns the heads that became ready.
  class Release
    class << self
      # `node` just reached a terminal settlement (or had its
      # failure_resolution flipped). Recomputes every affected head.
      def settled(node)
        ready = walk([node], [])
        TaskWaits.wake_observers(node.agent_run)
        ready
      end

      # The scheduler's defensive door for a countdown it does not trust:
      # the answer comes from Graph, never from the stored integer.
      def recompute(head)
        ready = []
        worklist = []
        resettle(head, ready, worklist)
        walk(worklist, ready)
      end

      private

        def walk(worklist, ready)
          while (node = worklist.shift)
            node.outgoing_edges.includes(:to_node).order(:id).each do |edge|
              head = edge.to_node
              next unless head.status == "queued"

              resettle(head, ready, worklist)
            end
          end
          ready.uniq
        end

        def resettle(head, ready, worklist)
          sources = head.sources.where(agent_run_edges: { agent_run_id: head.agent_run_id })
          settlements = dependency_settlements(sources)

          if Graph.skip_at_birth?(head.join_mode, settlements)
            Transition.node(head, status: "skipped", completed_at: Time.current)
            worklist << head
            return
          end

          countdown = Graph.initial_countdown(head.join_mode, head.quorum_k, settlements)
          head.update!(remaining_dependencies: countdown)

          if head.join_mode.present?
            settle_join(head, sources, settlements, worklist)
          elsif countdown.zero?
            ready << head
          end
        end

        # Every source still feeds this queued head, so none can be a
        # settled race loser. Count its own state through the same formula
        # without loading every dependency row on every fan completion.
        def dependency_settlements(sources)
          sources.reorder(nil).group(:status, :on_failure, :failure_resolution).count
            .flat_map do |(status, on_failure, failure_resolution), count|
              [Graph.settlement(status: status, on_failure: on_failure,
                failure_resolution: failure_resolution)] * count
            end
        end

        def settle_join(head, sources, settlements, worklist)
          if head.remaining_dependencies.zero?
            Transition.node(
              head,
              status: "completed",
              completed_at: Time.current,
              output_summary: {
                "joined" => head.join_mode,
                "outcomes" => Graph.join_outcomes(sources.index_by(&:node_key)),
              }
            )
            # A race with `cancel_losers` stops the branches nothing is
            # waiting for; whatever became terminal now cascades in this
            # same walk.
            worklist.concat(CancelLosers.call(head))
            worklist << head
          elsif (failure = Graph.join_failure(head.join_mode, head.quorum_k, settlements))
            Transition.node(
              head,
              status: "failed",
              completed_at: Time.current,
              error_key: failure,
              output_summary: {
                "join_failure" => failure,
                "outcomes" => Graph.join_outcomes(sources.index_by(&:node_key)),
              }
            )
            # A failed race ends the race too: `quorum_unreachable` can settle
            # while sources are still in flight.
            worklist.concat(CancelLosers.call(head))
            # A settled failure cascades exactly as the formula reads it:
            # absorb resolved, propagate skips, halt holds for adjudication.
            worklist << head if Graph.settlement_of(head) != :pending
          end
        end
    end
  end
end
