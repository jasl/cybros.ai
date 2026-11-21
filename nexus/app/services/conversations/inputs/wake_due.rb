module Conversations
  module Inputs
    # Recover an immediate or scheduled drain whose after-commit wake was lost.
    # Retained rows advance the cursor even when their room cannot drain.
    class WakeDue
      BUDGET = 500
      DUE_AT = Arel.sql("COALESCE(deliver_at, created_at)")

      def self.call(...) = new(...).call

      def initialize(cutoff: nil, after_at: nil, after_id: 0)
        @cutoff = cutoff ? Time.zone.iso8601(cutoff) : DatabaseClock.now
        @after_at = after_at
        @after_id = after_id
      end

      def call
        rows = frontier
        ids = drainable_hosts(rows)
        ActiveJob.perform_all_later(ids.map { |id| DrainJob.new(id) })
        Sweeps::Pass.new(
          counts: { scanned: rows.length, woken: ids.length },
          cursor: cursor(rows), more: rows.length == BUDGET
        )
      end

      private

        def frontier
          scope = Input.where(host_type: "Conversation", state: "pending")
            .where(DUE_AT.lteq(@cutoff))
          if @after_at
            scope = scope.where("(#{DUE_AT}, id) > (?, ?)", Time.zone.iso8601(@after_at), @after_id)
          end
          scope.order(DUE_AT, :id).limit(BUDGET).pluck(DUE_AT, :id, :host_id)
        end

        def drainable_hosts(rows)
          ids = rows.map(&:last).uniq
          hosts = Conversation.listable.where(id: ids)
          busy = Turn.active.where("turns.conversation_id = conversations.id")
          inputs = Input.where(host_type: "Conversation").where("inputs.host_id = conversations.id")
          first = inputs.pending.due(@cutoff).order(:queue_position).limit(1).select(:id)
          head = inputs.waiting_at(@cutoff).limit(1).select(:state)
          # The FIFO index picks one due row to represent the room. Only its
          # page evaluates the kernel-first head, which can be blocked.
          eligible = "CASE WHEN (#{first.to_sql}) IN (?) THEN (#{head.to_sql}) = 'pending' ELSE FALSE END"
          ids & hosts.where.not(busy.arel.exists).where(eligible, rows.map(&:second)).ids
        end

        def cursor(rows)
          at, id = rows.last
          [@cutoff.iso8601(6), at&.iso8601(6) || @after_at, id || @after_id]
        end
    end
  end
end
