module ScheduledJobs
  class DispatchDue
    BUDGET = 200

    def self.call(...) = new(...).call

    def initialize(cutoff: nil, after_at: nil, after_id: 0)
      @cutoff = cutoff ? Time.iso8601(cutoff) : DatabaseClock.now
      @after_at = after_at && Time.iso8601(after_at)
      @after_id = after_id
    end

    def call
      rows = frontier
      dispatched = rows.count { |_at, id, public_id| dispatch(id, public_id) }
      at, id, = rows.last
      Sweeps::Pass.new(counts: { scanned: rows.length, dispatched: dispatched },
        cursor: [@cutoff.iso8601(6), (at || @after_at)&.iso8601(6), id || @after_id],
        more: rows.length == BUDGET)
    end

    private

      def dispatch(id, public_id)
        Dispatch.call(id: id, cutoff: @cutoff) == :dispatched
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "scheduled_job_dispatch_failed", scheduled_job_public_id: public_id })
        false
      end

      def frontier
        scope = ScheduledJob.due(@cutoff)
        scope = scope.where("(next_run_at, id) > (?, ?)", @after_at, @after_id) if @after_at
        scope.order(:next_run_at, :id).limit(BUDGET).pluck(:next_run_at, :id, :public_id)
      end
  end
end
