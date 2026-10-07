module AgentRuns
  # Turn-owned work must be read before the reply becomes final. When the
  # mainline is idle, a continuation consumes those settled results. Detached
  # conversation-lifetime work is delivered by ResultDelivery after the reply instead.
  # Standalone loops have no later turn, so they consume every result here.
  class WakeContinuation
    KEY_PREFIX = "w".freeze

    class << self
      # Returns the appended continuation's key, or nil when there was
      # nothing to deliver. Level-triggered and safe to run on any wake: a
      # second pass finds the sinks delivered and does nothing. A fast
      # background result must not change its delivery into the current reply.
      def call(agent_run:)
        return nil unless agent_run.graph_mutable?
        return nil if agent_run.delivered?
        return nil if agent_run.mainline_live?

        pending = undelivered(agent_run, lifetime: ("turn" unless agent_run.standalone?))
        return nil if pending.empty?

        source = agent_run.mainline_tail
        return nil if source.nil?

        new(agent_run, source, pending).append
      end

      # The follow-up plant: the same continuation with nothing detached
      # to read — one more mainline round after `source`, so the inputs bound
      # at quiescence have a boundary to land at.
      def plant(agent_run:, source:) = new(agent_run, source, []).append

      # A turn-owned result is accepted only by a consumer that constrains
      # final delivery. A detached conversation-lifetime reader may use the
      # same material later, but cannot discharge that reporting obligation.
      # Standalone loops await all work, so every consumer qualifies there.
      # Filter before the bounded window so background tips cannot hide an
      # outstanding turn-owned obligation from the wake.
      def undelivered(agent_run, lifetime: nil)
        standalone = agent_run.standalone?
        settled = TaskResultProjection.tips(agent_run, sinks(agent_run), unmailed: true)
        settled.select! { |node| node.lifetime == lifetime } if lifetime
        return settled if settled.empty?

        spliced = Set.new
        final_spliced = Set.new
        agent_run.agent_run_tasks.pluck(:input_from_node_keys, :result_from_node_keys, :detached, :lifetime)
          .each do |history_keys, result_keys, detached, lifetime|
            keys = Array(history_keys) + Array(result_keys)
            spliced.merge(keys)
            final_spliced.merge(keys) if standalone || !detached || lifetime == "turn"
          end
        # Bounded because the door is: an unbounded all-or-nothing set
        # would refuse forever. The next pass delivers the remainder.
        settled.reject do |node|
          reads = !standalone && node.lifetime == "turn" ? final_spliced : spliced
          reads.include?(node.node_key)
        end.first(Tasks::Compile::KERNEL_MAX_DEPENDENCIES_PER_TASK)
      end

      # THE SET THE WAKE DELIVERS, as rows, before a race among them is
      # read as its selection: every settled detached row no step reads
      # (`Delivery.settled`) and nothing live holds back.
      def sinks(agent_run)
        standalone = agent_run.standalone?
        rows = unread_rows(agent_run, standalone: standalone)
          .where(detached: true, status: AgentRunTask::TERMINAL_STATUSES, result_delivered_at: nil)
          .order(:completed_at, :id).to_a
        Delivery.settled(agent_run, rows, standalone: standalone)
      end

      private

        # The consumers that grow with the loop's history, as anti-joins:
        # a reader that names the row (reading implies waiting, so it has an
        # edge from it), a race's barrier that stands for it, an expansion
        # that replaced it — one placed from the row's own tip, so it waits on
        # the row, where a compaction summarizer under a round is placed ahead
        # of it and replaces nothing — and a spawn's delegation, which owns the
        # child's one report while the await beside it is a short wait that
        # never owns completion (`Delegations::Settlement`). A structural wait
        # consumes nothing: it only defers delivery (`Delivery.ready`).
        def unread_rows(agent_run, standalone:)
          binds = { standalone: standalone, await: AgentRunTasks::AwaitTask.sti_name,
                    delegation: AgentRunTasks::DelegationTask.sti_name }
          agent_run.agent_run_tasks.where(barrier_node_id: nil).where(<<~SQL.squish, binds)
            NOT EXISTS (
              SELECT 1 FROM agent_run_edges edges
              JOIN agent_run_tasks consumers ON consumers.id = edges.to_node_id
              WHERE edges.from_node_id = agent_run_tasks.id
                AND (agent_run_tasks.node_key = ANY(consumers.input_from_node_keys)
                  OR agent_run_tasks.node_key = ANY(consumers.result_from_node_keys))
                AND (:standalone OR agent_run_tasks.lifetime = 'conversation'
                  OR NOT consumers.detached OR consumers.lifetime = 'turn')
            )
            AND NOT EXISTS (
              SELECT 1 FROM agent_run_edges expansions
              JOIN agent_run_tasks children ON children.id = expansions.to_node_id
              WHERE expansions.from_node_id = agent_run_tasks.id AND expansions.structural
                AND children.expansion_parent_id = agent_run_tasks.id
            )
            AND NOT (agent_run_tasks.type = :await AND EXISTS (
              SELECT 1 FROM agent_run_tasks completions
              WHERE completions.expansion_parent_id = agent_run_tasks.expansion_parent_id
                AND completions.type = :delegation
            ))
          SQL
        end
    end

    def initialize(agent_run, source, pending)
      @agent_run = agent_run
      @source = source
      @pending = pending
      @key = free_key
    end

    def append
      result = Tasks::Append.call_locked(Tasks::Append::Command.kernel(
        agent_run: @agent_run, steps: [Tasks::Step.inheriting(@source, key: @key)], tip: tip,
        origin: "kernel"
      ))
      if result.applied?
        AgentRun::Narration.record(@agent_run, @pending.map { |tip| accepted_item(tip) })
        return @key
      end

      Rails.logger.error(
        "event=agent_run_wake_refused loop=#{@agent_run.public_id} " \
        "source=#{@source.node_key} pending=#{@pending.length} " \
        "reason=#{result.errors.first&.fetch("code", nil) || result.outcome}"
      )
      nil
    end

    private

      # The wake WAITS only on tips that answered and READS every pending
      # one — the kernel's `waits ≠ reads` privilege — so a skipped tip
      # never makes the wake round born skipped and swallow its siblings. A
      # tip behind a stage's boundary crosses it as a result: the wake is
      # inside no stage.
      def tip
        answered = @pending.select { |tip| %i[success resolved].include?(Graph.settlement_of(tip)) }
        @boundary = ExpansionOwnership.owners(@agent_run, @pending.map(&:node_key))
        Tasks::Tip.new(
          mainline: Tasks::Known.of(@source),
          waits: answered.map { |tip| Tasks::Known.of(tip) },
          reads: @pending.map { |tip| Tasks::Known.of(tip, result_only: @boundary.key?(tip.node_key)) },
          mark: Tasks::Compile::ROUND, detached: false, lifetime: @source.lifetime, wake: @source.wake
        )
      end

      # The drain IS acceptance: the same `input_accepted{origin:
      # task_result}` item the mail path narrates for a woken turn, minus
      # the input row a graph read never needs — a feed reader sees every
      # receipt, on either path. Buffered by `Narration` to the append's
      # own commit, so a refused append emits nothing; once per tip,
      # because a read tip is spliced and the mail
      # (`WakeContinuation.undelivered`) never sees it again.
      def accepted_item(tip)
        {
          type: "input_accepted",
          payload: {
            "origin" => ConversationInput::TASK_RESULT_ORIGIN,
            "run_public_id" => @agent_run.public_id,
            "task_key" => TaskResultEnvelope.call_key(tip, boundary: @boundary.key?(tip.node_key)),
          },
        }
      end

      def free_key
        used = @agent_run.agent_run_tasks.pluck(:node_key).to_set
        number = 1
        number += 1 while used.include?("#{KEY_PREFIX}#{number}")
        "#{KEY_PREFIX}#{number}"
      end
  end
end
