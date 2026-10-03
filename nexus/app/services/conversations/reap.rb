module Conversations
  # Reaps the whole aggregate via `destroy` (the cascade guards live in
  # callbacks); a pinned ancestor is a level-triggered skip; the fork-vs-reap
  # interlock is the row lock, with the RESTRICT rescue (23001) as defense in depth.
  class Reap
    def self.call(...) = new(...).call

    # One row, now: a tombstoned side skips the retention clock. The
    # caller holds the row's lock; a fence answers false and the sweep
    # rediscovers the row.
    def self.reap_now(id) = new(batch: 1).send(:reap_one, id)

    # Shared with workspace collection. The caller holds the conversation
    # lock: retire its engines before deleting the variants that identify
    # their host. A draining loop keeps its own settlement/reap lifecycle.
    def self.destroy_aggregate(conversation)
      return false if AgentLoops::Delegations.retained_conversation?(conversation)

      tombstoned_at = conversation.tombstoned_at || Time.current
      conversation.hosted_agent_loops.find_each do |agent_loop|
        agent_loop.with_lock do
          AgentLoops::Stop.stop_now(agent_loop) unless agent_loop.terminal?
          agent_loop.update!(tombstoned_at: tombstoned_at) unless agent_loop.tombstoned?
        end
      end
      ModelInvocations::DrainSettled.call(conversation.model_invocations)
      conversation.destroy!
      true
    end

    def initialize(batch:, after_tombstoned_at: nil, after_id: 0)
      @batch = batch
      @cutoff = Conversation::RETENTION_PERIOD.ago
      @after_tombstoned_at = Time.zone.iso8601(after_tombstoned_at) if after_tombstoned_at
      @after_id = after_id
    end

    def call
      rows = candidates.select(:id, :tombstoned_at).to_a
      reaped = rows.count { |row| reap_one(row.id) }

      # One sweep's tally, the accepted answer's value.
      Outcome.accepted(Sweeps::Pass.new(
        counts: { scanned: rows.length, reaped: reaped },
        cursor: rows.last && [rows.last.tombstoned_at.iso8601(6), rows.last.id],
        more: @batch.positive? && rows.length == @batch
      ))
    end

    private

      # Every tombstone costs source budget, even when age, a fork pin or
      # unsettled work retains it. The locked writer below owns those checks.
      def candidates
        scope = Conversation.where.not(tombstoned_at: nil)
        if @after_tombstoned_at
          scope = scope.where("(conversations.tombstoned_at, conversations.id) > (?, ?)",
            @after_tombstoned_at, @after_id)
        end
        scope
          .order(:tombstoned_at, :id)
          .limit(@batch)
      end

      def reap_one(id)
        ApplicationRecord.transaction(requires_new: true) do
          locked = Conversation.lock.find_by(id: id)
          next false if locked.nil?

          eligible = ApplicationRecord.uncached do
            locked.tombstoned_at.present? &&
              (locked.side? || locked.tombstoned_at <= @cutoff) &&
              !ConversationAncestry.where(ancestor_conversation_id: id).exists? &&
              !nonterminal_work_for(id)
          end
          next false unless eligible

          # The cascade takes the conversation's memory pointers and its
          # own store rows (StoreHost) with the row.
          self.class.destroy_aggregate(locked)
        end
      rescue ActiveRecord::StatementInvalid => error
        case error.cause
        when PG::RestrictViolation
          # A concurrent fork won the pin between our re-check and the final
          # DELETE. Level-triggered: the row is rediscovered when the
          # descendant dies.
          false
        else
          raise
        end
      end

      def nonterminal_work_for(id)
        # Pending settlement may still write a receipt without holding the
        # invocation lock, so its aggregate remains until that obligation ends.
        ModelInvocation.nonterminal.where(conversation_id: id).exists? ||
          ModelInvocationAttempt.where(settlement_state: "pending")
            .joins(:model_invocation)
            .where(model_invocations: { conversation_id: id })
            .exists?
      end
  end
end
