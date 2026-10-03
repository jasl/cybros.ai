module AgentLoops
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
      rows = source.select(:id, :agent_loop_id, :public_id, :status, :failure_reason_key).to_a
      touched = []
      recorded = rows.count do |invocation|
        record(invocation).tap do |applied|
          touched << invocation.agent_loop_id if applied
        end
      end
      ActiveJob.perform_all_later(touched.uniq.map { |agent_loop_id| ScheduleJob.new(agent_loop_id) })

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
          .where.not(agent_loop_id: nil)
          .where(id: (@after_id + 1)..)
          .order(:id).limit(@batch)
      end

      def record(candidate)
        # Terminal status and the sealed request cannot change. Inspect only
        # refusal candidates before taking any lock, so successful rounds do
        # not acquire the conversation or read their request bodies again.
        turn = if candidate.replay_refused?
          ConversationTurn.select(:conversation_id, :public_id).joins(:agent_loops)
            .find_by(agent_loops: { id: candidate.agent_loop_id })
        end
        ApplicationRecord.transaction(requires_new: true) do
          conversation = Conversation.lock.find_by(id: turn.conversation_id) if turn
          agent_loop = AgentLoop.lock.find_by(id: candidate.agent_loop_id)
          invocation = ModelInvocation.lock.find_by(id: candidate.id)
          next false if agent_loop.nil? || invocation.nil?
          next false unless invocation.terminal? && invocation.terminal_event_recorded_at.nil?

          ApplyStepResult.call(agent_loop: agent_loop, invocation: invocation)
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
          context: { event: "agent_loop_step_converge_failed", invocation_public_id: candidate.public_id })
        false
      end
  end
end
