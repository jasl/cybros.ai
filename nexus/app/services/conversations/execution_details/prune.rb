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
            Run.where(account: @account, details_pruned_at: nil, status: Run::TERMINAL_STATUSES)
              .where.not(variant_id: nil)
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
        def prune_loop(run)
          with_host_lock(run) do
            next false unless run.terminal? &&
              run.details_pruned_at.nil? && run.completed_at && run.completed_at <= @cutoff
            variant = run.variant
            next false unless variant.terminal?
            next false if preparing_history?(variant.turn)
            next false if unsettled?(run.model_invocations) || Runs::Delegations.retained?(run)

            # A failed candidate replaced by an edit does not settle again
            # when its loop stops. Preserve its landed words before removal.
            RetainedSteers.archive(run)
            variant.content_bodies.where(role: %w[preface reasoning reasoning_trace]).destroy_all
            # The initial variant selection stays immutable. Retain the actual
            # terminal mainline before removing the only evidence of a switch.
            selection = Runs::CurrentModel.selection_of(run.mainline_tail)
            retained_model = Run::RetainedModel.capture(selection) if selection
            Runs::Reap.destroy_details(run)
            run.update!(details_pruned_at: Time.current, retained_model: retained_model)
            true
          end
        end

        def prune_invocation(invocation)
          with_host_lock(invocation) do
            id = invocation.id
            next false unless invocation.terminal? &&
              invocation.terminal_at && invocation.terminal_at <= @cutoff && invocation.terminal_event_recorded_at
            variant = Variant.find_by(model_invocation_id: id)
            next false unless variant&.terminal?
            next false if unsettled?(ModelInvocation.where(id: id)) ||
              Runs::Delegations.owed_result?(variant.turn)

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
          variants = Turn.where(id: hosts.where.not(active_turn_id: nil).select(:active_turn_id))
            .select(:active_variant_id)
          loops = Run.where(variant_id: variants)
            .where.not(status: Run::TERMINAL_STATUSES)
          sealed = ContentBody.joins(:task)
            .where(role: "input").where.not(sealed_at: nil)
            .where(tasks: { node_key: Inputs::ApplyNext::SEED_ROUND_KEY })
            .where("tasks.run_id = runs.id").offset(0)
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
