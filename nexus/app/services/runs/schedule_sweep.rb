module Runs
  # Live work and undelivered background results have separate retained
  # frontiers. Paused, held and unstarted loops still need authority checks;
  # only running loops dispatch work. A blocked row advances its cursor.
  class ScheduleSweep
    BATCH = 200

    def self.call(...) = new(...).call

    def initialize(schedule_after_id: 0, result_delivery_after_id: 0, batch: BATCH)
      @schedule_after_id = schedule_after_id
      @result_delivery_after_id = result_delivery_after_id
      @batch = batch
    end

    def call
      schedules, work = ApplicationRecord.uncached do
        page = schedule_window
        [page, candidates(page)]
      end
      mails = result_delivery_window
      work.each { |id| advance(id) }
      woken = mails.map(&:last).uniq.count { |id| wake_result_delivery(id) }
      cursors = [cursor(schedules.map(&:id), @schedule_after_id), cursor(mails.map(&:first), @result_delivery_after_id)]

      Sweeps::Pass.new(
        counts: { scanned: schedules.length + mails.length, result_delivery_woken: woken },
        cursor: cursors, more: cursors.any?
      )
    end

    private

      def schedule_window
        return [] if @schedule_after_id.nil?

        Run.where(status: Run::LIVE_STATUSES).where(id: (@schedule_after_id + 1)..)
          .order(:id).limit(@batch).select(:id, :status, :variant_id, :workspace_id, :creating_user_id, :stopped_at)
          .preload(:workspace, creating_user: [:steward, :derived_from]).to_a
      end

      # Discovery holds no locks. Only a positive candidate enters
      # ScheduleReady, which rereads current authority, steering and tasks
      # under the usual locks. A concurrent change can also send a precise
      # wake; the next fresh sweep revisits every live Run.
      def candidates(page)
        return [] if page.empty?

        ids = page.map(&:id)
        standalone = page.filter_map { |run| run.id if run.standalone? }
        hosted = ids - standalone
        needed = page.filter_map do |run|
          run.id if run.canceling? || run.stopped? || !run.workspace.data_writable_by?(run.creating_user)
        end
        needed.concat(SourceWork.stopped_source_ids(hosted))
        needed.concat(Steers::Synchronize.recovery_ids(standalone:, hosted:))
        needed.concat(ScheduleReady.recovery_candidates(Run.where(id: ids)).ids)
        ids & needed
      end

      def result_delivery_window
        return [] if @result_delivery_after_id.nil?

        ResultDelivery.recovery_candidates(after_id: @result_delivery_after_id, limit: @batch).pluck(:id, :run_id)
      end

      def cursor(ids, previous)
        ids.last if previous && @batch.positive? && ids.length == @batch
      end

      def advance(run_id)
        ScheduleReady.call(run_id: run_id)
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "run_schedule_sweep_failed", run_id: run_id })
      end

      def wake_result_delivery(run_id)
        run = Run.find_by(id: run_id)
        return false if run.nil? || !ResultDelivery.pending?(run)

        ResultDeliveryJob.perform_later(run_id)
        true
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "run_result_delivery_recovery_failed", run_public_id: run&.public_id })
        false
      end
  end
end
