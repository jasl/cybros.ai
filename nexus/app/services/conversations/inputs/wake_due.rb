module Conversations
  module Inputs
    # Busy rooms retain their due rows: the cursor must pass them even when
    # their drains cannot progress. The next recurring wake revisits them.
    class WakeDue
      BUDGET = 500

      def self.call(...) = new(...).call

      def initialize(cutoff: nil, after_at: nil, after_id: 0)
        @cutoff = cutoff ? Time.zone.iso8601(cutoff) : DatabaseClock.now
        @after_at = after_at
        @after_id = after_id
      end

      def call
        rows = frontier
        ids = rows.map(&:last).uniq
        ActiveJob.perform_all_later(ids.map { |id| DrainJob.new(id) })
        Sweeps::Pass.new(
          counts: { scanned: rows.length, woken: ids.length },
          cursor: cursor(rows), more: rows.length == BUDGET
        )
      end

      private

        def frontier
          scope = ConversationInput.where(host_type: "Conversation", state: "pending")
            .where(deliver_at: ..@cutoff)
          if @after_at
            scope = scope.where("(deliver_at, id) > (?, ?)", Time.zone.iso8601(@after_at), @after_id)
          end
          scope.order(:deliver_at, :id).limit(BUDGET).pluck(:deliver_at, :id, :host_id)
        end

        def cursor(rows)
          at, id = rows.last
          [@cutoff.iso8601(6), at&.iso8601(6) || @after_at, id || @after_id]
        end
    end
  end
end
