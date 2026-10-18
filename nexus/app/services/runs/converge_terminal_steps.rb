module Runs
  # Level-triggered: every step invocation that terminalized without its
  # graph knowing is applied under the ladder's order. Native replay refusals
  # lock their conversation before the loop and invocation; other results
  # need only the loop and invocation. The recurring floor recovers lost wakes.
  class ConvergeTerminalSteps
    class << self
      def call(batch: 200, after_id: 0, invocation_id: nil)
        new(batch, after_id, invocation_id).call
      end
    end

    def initialize(batch, after_id, invocation_id)
      @batch = batch
      @after_id = after_id
      @invocation_id = invocation_id
    end

    def call
      source = @invocation_id ? frontier.where(id: @invocation_id) : frontier
      rows = source.select(:id, :run_id, :public_id, :status, :failure_reason_key, :workload, :creating_user_id).to_a
      touched = []
      recorded = rows.count do |invocation|
        record(invocation).tap do |applied|
          touched << invocation.run_id if applied
        end
      end
      ActiveJob.perform_all_later(touched.uniq.map { |run_id| ScheduleJob.new(run_id) })

      Sweeps::Pass.new(
        counts: { scanned: rows.length, recorded: recorded },
        cursor: rows.last&.id || @after_id,
        more: @invocation_id.nil? && @batch.positive? && rows.length == @batch
      )
    end

    private

      def frontier
        ModelInvocation
          .where(status: ModelInvocation::TERMINAL_STATUSES)
          .where(terminal_event_recorded_at: nil)
          .where.not(run_id: nil)
          .where(id: (@after_id + 1)..)
          .order(:id).limit(@batch)
      end

      def record(candidate)
        # Terminal status and the sealed request cannot change. Inspect only
        # refusal candidates before taking any lock, so successful rounds do
        # not acquire the conversation or read their request bodies again.
        turn = if candidate.replay_refused?
          Turn.select(:conversation_id, :public_id).joins(:runs)
            .find_by(runs: { id: candidate.run_id })
        end
        ApplicationRecord.transaction(requires_new: true) do
          # Generated files insert ContentUploads anchored to the invocation's
          # creator. Pin that FK parent before the Run/Invocation suffix; this
          # is a lifetime anchor even if the principal was suspended meanwhile.
          if candidate.workload == "image_generation" && candidate.completed?
            User.where(id: candidate.creating_user_id).lock("FOR KEY SHARE").pick(:id)
          end
          conversation = Conversation.lock.find_by(id: turn.conversation_id) if turn
          run = Run.lock.find_by(id: candidate.run_id)
          invocation = ModelInvocation.lock.find_by(id: candidate.id)
          next false if run.nil? || invocation.nil?
          next false unless invocation.terminal? && invocation.terminal_event_recorded_at.nil?

          ApplyStepResult.call(run: run, invocation: invocation)
          # A retry or compaction repair may keep the turn running. The
          # refusal still changes later assembly, never this sealed request.
          conversation.downgrade_reasoning_replay(turn: turn) if conversation
          invocation.update!(terminal_event_recorded_at: DatabaseClock.now)
          true
        end
      rescue StandardError => error
        # Failed rows advance this chain's cursor; the next recurring wake
        # retries them without holding later results behind the same window.
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "task_converge_failed", invocation_public_id: candidate.public_id })
        false
      end
  end
end
