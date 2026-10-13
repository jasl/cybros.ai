module AgentRuns
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
      schedules = schedule_window
      mails = result_delivery_window
      schedules.each { |id| advance(id) }
      woken = mails.map(&:last).uniq.count { |id| wake_result_delivery(id) }
      cursors = [cursor(schedules, @schedule_after_id), cursor(mails.map(&:first), @result_delivery_after_id)]

      Sweeps::Pass.new(
        counts: { scanned: schedules.length + mails.length, result_delivery_woken: woken },
        cursor: cursors, more: cursors.any?
      )
    end

    private

      def schedule_window
        return [] if @schedule_after_id.nil?

        AgentRun.where(status: AgentRun::LIVE_STATUSES).where(id: (@schedule_after_id + 1)..)
          .order(:id).limit(@batch).pluck(:id)
      end

      def result_delivery_window
        return [] if @result_delivery_after_id.nil?

        ResultDelivery.recovery_candidates(after_id: @result_delivery_after_id, limit: @batch).pluck(:id, :agent_run_id)
      end

      def cursor(ids, previous)
        ids.last if previous && @batch.positive? && ids.length == @batch
      end

      def advance(agent_run_id)
        ScheduleReady.call(agent_run_id: agent_run_id)
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "agent_run_schedule_sweep_failed", agent_run_id: agent_run_id })
      end

      def wake_result_delivery(agent_run_id)
        agent_run = AgentRun.find_by(id: agent_run_id)
        return false if agent_run.nil? || !ResultDelivery.pending?(agent_run)

        ResultDeliveryJob.perform_later(agent_run_id)
        true
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "agent_run_result_delivery_recovery_failed", run_public_id: agent_run&.public_id })
        false
      end
  end
end
