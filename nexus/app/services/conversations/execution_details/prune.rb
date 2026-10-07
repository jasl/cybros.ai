module Conversations
  module ExecutionDetails
    # Retains the conversation's words while discarding completed execution
    # evidence. The source window is materialized before any dependency probe;
    # a retained owner consumes budget and the cursor advances past it.
    class Prune
      def self.call(...) = new(...).call

      def initialize(account:, batch:, kind: "loops", after_at: nil, after_id: 0, cutoff_at: nil)
        @account = account
        @batch = batch
        @kind = kind
        @after_at = Time.zone.iso8601(after_at) if after_at
        @after_id = after_id
        @cutoff_at = Time.zone.iso8601(cutoff_at) if cutoff_at
      end

      def call
        days = @account.execution_details_retention_days
        return pass([], 0) unless days

        @cutoff = [@cutoff_at, days.days.ago].compact.min
        rows = candidates.to_a
        pruned = rows.count { |row| @kind == "loops" ? prune_loop(row) : prune_invocation(row) }
        pass(rows, pruned)
      end

      private

        def pass(rows, pruned)
          last = rows.last
          Sweeps::Pass.new(counts: { scanned: rows.length, pruned: pruned },
            cursor: last && [last.public_send(clock_column).iso8601(6), last.id, @cutoff.iso8601(6)],
            more: @batch.positive? && rows.length == @batch)
        end

        def clock_column = @kind == "loops" ? :completed_at : :terminal_at

        def candidates
          scope = if @kind == "loops"
            AgentRun.where(account: @account, details_pruned_at: nil, status: AgentRun::TERMINAL_STATUSES)
              .where.not(conversation_turn_variant_id: nil)
          else
            ModelInvocation.where(account: @account, status: ModelInvocation::TERMINAL_STATUSES)
              .where.not(conversation_id: nil)
          end
          scope = scope.where(clock_column => ..@cutoff)
          if @after_at
            cursor_sql = @kind == "loops" ? "(completed_at, id) > (?, ?)" : "(terminal_at, id) > (?, ?)"
            scope = scope.where(cursor_sql, @after_at, @after_id)
          end
          scope.order(clock_column, :id).limit(@batch)
        end

        # The conversation lock precedes the loop lock, as in convergence and
        # materialization. Own-conversation request sealing cannot observe half
        # a prune; fork history also rechecks the marker after reading.
        def prune_loop(agent_run)
          with_host_lock(agent_run) do
            next false unless agent_run.terminal? &&
              agent_run.details_pruned_at.nil? && agent_run.completed_at && agent_run.completed_at <= @cutoff
            variant = agent_run.conversation_turn_variant
            next false unless variant.terminal?
            next false if preparing_history?(variant.conversation_turn)
            next false if unsettled?(agent_run.model_invocations) || AgentRuns::Delegations.retained?(agent_run)

            # A failed candidate replaced by an edit does not settle again
            # when its loop stops. Preserve its landed words before removal.
            RetainedSteers.archive(agent_run)
            variant.content_bodies.where(role: %w[preface reasoning reasoning_trace]).destroy_all
            AgentRuns::Reap.destroy_details(agent_run)
            agent_run.update!(details_pruned_at: Time.current)
            true
          end
        end

        def prune_invocation(invocation)
          with_host_lock(invocation) do
            id = invocation.id
            next false unless invocation.terminal? &&
              invocation.terminal_at && invocation.terminal_at <= @cutoff && invocation.terminal_event_recorded_at
            variant = ConversationTurnVariant.find_by(model_invocation_id: id)
            next false unless variant&.terminal?
            next false if unsettled?(ModelInvocation.where(id: id)) ||
              AgentRuns::Delegations.owed_result?(variant.conversation_turn)

            variant.content_bodies.where(role: %w[preface reasoning reasoning_trace]).destroy_all
            variant.update!(details_pruned_at: Time.current)
            ModelInvocations::DrainSettled.call(ModelInvocation.where(id: id))
            true
          end
        end

        # ResultDeliverySeed may prepare a previously unavailable first round while
        # holding only its loop lock. Protect that actual unsealed reader,
        # including a fork whose prefix still reaches this turn. Already sealed
        # active turns carry their own request and do not retain old graphs.
        def preparing_history?(turn)
          inherited = ConversationAncestry.where(ancestor_conversation_id: turn.conversation_id,
            boundary_position: turn.position..).select(:conversation_id)
          hosts = Conversation.where(id: turn.conversation_id).or(Conversation.where(id: inherited))
          variants = ConversationTurn.where(id: hosts.where.not(active_turn_id: nil).select(:active_turn_id))
            .select(:active_variant_id)
          loops = AgentRun.where(conversation_turn_variant_id: variants)
            .where.not(status: AgentRun::TERMINAL_STATUSES)
          sealed = ContentBody.joins(:agent_run_task)
            .where(role: "input").where.not(sealed_at: nil)
            .where(agent_run_tasks: { node_key: Inputs::ApplyNext::SEED_ROUND_KEY })
            .where("agent_run_tasks.agent_run_id = agent_runs.id").offset(0)
          loops.where.not(sealed.arel.exists).exists?
        end

        def with_host_lock(execution)
          conversation = execution.conversation
          return false unless conversation

          conversation.with_lock(requires_new: true) do
            execution.lock!
            yield
          end
        rescue ActiveRecord::RecordNotFound
          false
        end

        def unsettled?(invocations)
          invocations.nonterminal.exists? || ModelInvocationAttempt
            .where(model_invocation_id: invocations.select(:id), settlement_state: "pending").exists?
        end
    end
  end
end
