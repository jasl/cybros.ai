module AgentLoops
  # Live work and undelivered background results have separate retained
  # frontiers. Paused, held and unstarted loops still need authority checks;
  # only running loops dispatch work. A blocked row advances its cursor.
  class ScheduleSweep
    BATCH = 200

    def self.call(...) = new(...).call

    def initialize(schedule_after_id: 0, mail_after_id: 0, batch: BATCH)
      @schedule_after_id = schedule_after_id
      @mail_after_id = mail_after_id
      @batch = batch
    end

    def call
      schedules = schedule_window
      mails = mail_window
      schedules.each { |id| advance(id) }
      woken = mails.map(&:last).uniq.count { |id| wake_mail(id) }
      cursors = [cursor(schedules, @schedule_after_id), cursor(mails.map(&:first), @mail_after_id)]

      Sweeps::Pass.new(
        counts: { scanned: schedules.length + mails.length, mail_woken: woken },
        cursor: cursors, more: cursors.any?
      )
    end

    private

      def schedule_window
        return [] if @schedule_after_id.nil?

        AgentLoop.where(status: AgentLoop::LIVE_STATUSES).where(id: (@schedule_after_id + 1)..)
          .order(:id).limit(@batch).pluck(:id)
      end

      def mail_window
        return [] if @mail_after_id.nil?

        Mail.recovery_candidates(after_id: @mail_after_id, limit: @batch).pluck(:id, :agent_loop_id)
      end

      def cursor(ids, previous)
        ids.last if previous && @batch.positive? && ids.length == @batch
      end

      def advance(agent_loop_id)
        ScheduleReady.call(agent_loop_id: agent_loop_id)
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "agent_loop_schedule_sweep_failed", agent_loop_id: agent_loop_id })
      end

      def wake_mail(agent_loop_id)
        agent_loop = AgentLoop.find_by(id: agent_loop_id)
        return false if agent_loop.nil? || !Mail.pending?(agent_loop)

        MailJob.perform_later(agent_loop_id)
        true
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "agent_loop_mail_recovery_failed", agent_loop_public_id: agent_loop&.public_id })
        false
      end
  end
end
