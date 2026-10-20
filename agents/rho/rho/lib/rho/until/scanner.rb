require_relative "recovery"

module Rho
  module Until
    # One in-memory traversal of durable Run facts. Each principal gets one
    # request/decision per turn; an empty page advances just like a full one.
    class Scanner
      YIELD_SECONDS = 0.01
      RETRY_SECONDS = 5.0
      State = Struct.new(:agent, :after, :page, :index, :done, :retry_at, keyword_init: true)

      def initialize(client:, owner_public_id:, agent_public_ids:, timeout_seconds:, active:, log: nil,
                     sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @client, @active, @log, @sleeper, @clock = client, active, log, sleeper, clock
        @states = agent_public_ids.uniq.map { |agent| State.new(agent: agent, index: 0, retry_at: 0) }
        @recovery = Recovery.new(owner_public_id: owner_public_id, timeout_seconds: timeout_seconds, log: log, sleeper: sleeper)
      end

      def call
        started = @clock.call
        pages = 0
        while @active.call && @states.any? { |state| !state.done }
          @states.each do |state|
            return unless @active.call
            next if state.done || state.retry_at > @clock.call

            pages += advance(state)
            @sleeper.call(YIELD_SECONDS)
          end
          pending = @states.reject(&:done)
          delay = pending.map(&:retry_at).min.to_f - @clock.call
          @sleeper.call([delay, 30].min) if delay.positive?
        end
        @log&.info("until.scan_completed", pages: pages, principals: @states.length, seconds: @clock.call - started) if @active.call
      end

      private

        def advance(state)
          if state.page
            row = state.page.items[state.index]
            @recovery.call(workspace: @client.workspace(row.workspace_public_id), run_public_id: row.public_id,
              conversation_public_id: row.conversation_public_id, turn_public_id: row.turn_public_id)
            state.index += 1
            finish_page(state) if state.index == state.page.items.length
            0
          else
            state.page = @client.work.run_candidates(agent_public_id: state.agent, after: state.after)
            state.index = 0
            finish_page(state) if state.page.items.empty?
            1
          end
        rescue CybrosAgent::Api::NotFound, CybrosAgent::Api::Forbidden, Rho::StateError, KeyError, ArgumentError => error
          raise unless state.page

          @log&.warn("until.candidate_skipped", agent: state.agent, error_class: error.class.name,
            detail: CybrosAgent::Redaction.call(error.message))
          state.index += 1
          finish_page(state) if state.index == state.page.items.length
          0
        rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
          delay = case error
          in CybrosAgent::Api::RateLimited then error.retry_after || RETRY_SECONDS
          else RETRY_SECONDS
          end
          state.retry_at = @clock.call + [delay, RETRY_SECONDS].max
          @log&.warn("until.scan_deferred", agent: state.agent, error_class: error.class.name,
            detail: CybrosAgent::Redaction.call(error.message))
          0
        end

        def finish_page(state)
          state.after = state.page.next_after
          state.done = state.after.nil?
          state.page = nil
        end
    end
  end
end
