require "securerandom"

module Rho
  class Runner
    # Optional signaling on the existing control reactor. The tool handler
    # owns its transport and OS resource; this bridge owns neither execution
    # nor cleanup. A permission timeout only closes the data gate.
    class ClaimRealtime
      class Closed < Error; end
      POLL_SECONDS = 0.5
      WORKER_WAIT_SECONDS = 0.01
      Offer = Data.define(:connection_id, :sdp, :answer)
      private_constant :Offer

      def initialize(task:, claim_token:, clock:, log:)
        @task = task
        @claim_token = claim_token
        @clock = clock
        @log = log
        @mutex = Mutex.new
        @pending = nil
        @connection_id = nil
        @snapshot = nil
        @valid_until = 0.0
        @allowed_since = nil
        @next_at = nil
        @closed = false
        @stopped = false
      end

      # Worker-only. Stop the previous transport entrance before calling;
      # retries/reconnection never restart the tool or replay its inputs.
      def offer(sdp:, reopen: true)
        context = ExecutionContext.current
        context&.raise_if_cancelled!
        answer = Thread::Queue.new
        @mutex.synchronize do
          raise Error, "realtime signaling is closed" if @stopped
          raise Closed, "realtime connection is closed" if @closed && !reopen
          raise Error, "a realtime offer is already pending" if @pending

          @connection_id = SecureRandom.uuid_v7
          @snapshot = nil
          @valid_until = 0.0
          @closed = false
          @pending = Offer.new(connection_id: @connection_id, sdp: sdp, answer: answer)
        end
        loop do
          context&.raise_if_cancelled!
          result = answer.pop(timeout: WORKER_WAIT_SECONDS)
          next unless result
          raise result.fetch(:error) if result.key?(:error)

          return result.fetch(:value)
        end
      end

      # Every new input/capture/send checks this locally, including during a
      # stalled HTTP read. No response can extend the budget by arriving late.
      def allowed?
        @mutex.synchronize { !@stopped && !@closed && @clock.call < @valid_until }
      end

      # A viewer may observe only the remainder of this same window. It
      # discounts its own request round trip rather than starting a new lease.
      def remaining_ms
        @mutex.synchronize do
          @stopped || @closed ? 0 : [[((@valid_until - @clock.call) * 1000).floor, 0].max, 1000].min
        end
      end

      # Queued bytes from before the current uninterrupted permission window
      # cannot become fresh input merely because a later read reauthorized it.
      def received_allowed?(age:)
        @mutex.synchronize do
          now = @clock.call
          !@stopped && !@closed && now < @valid_until && !@allowed_since.nil? && now - age >= @allowed_since
        end
      end

      def snapshot = @mutex.synchronize { @snapshot }

      def closed? = @mutex.synchronize { @stopped || @closed }

      def close
        @mutex.synchronize do
          @stopped = true
          @valid_until = 0.0
        end
        nil
      end

      def wait(now = @clock.call)
        @mutex.synchronize do
          next nil if @stopped
          next 0.0 if @pending

          @next_at && [@next_at - now, 0.0].max
        end
      end

      # Reactor-only. An unavailable read preserves at most the remaining
      # original window. Explicit refusal permanently closes this handshake.
      def flush
        pending, id = @mutex.synchronize do
          next [nil, nil] if @stopped
          next [@pending, @connection_id] if @pending
          next [nil, nil] if @closed || !@next_at || @clock.call < @next_at

          [nil, @connection_id]
        end
        return unless id

        delay = POLL_SECONDS
        started = @clock.call
        value = if pending
          # Reconcile a lost prior offer response before replacing it. This
          # reads only the original claim; no tool or input is replayed.
          previous = @task.realtime(claim_token: @claim_token).connection_id
          @task.offer_realtime(claim_token: @claim_token, connection_id: id, sdp: pending.sdp, previous_connection_id: previous)
        else
          @task.realtime(claim_token: @claim_token)
        end
        @mutex.synchronize do
          if id == @connection_id && !@stopped
            @snapshot = value
            @closed ||= value.closed? || value.connection_id != id
            budget = [[value.max_age_ms, 1000].min, 0].max / 1000.0
            @allowed_since = @clock.call if @clock.call >= @valid_until
            @valid_until = value.active? && !@closed ? started + budget : 0.0
          end
          @pending = nil if @pending.equal?(pending)
        end
        pending&.answer&.push(value: value)
      rescue CybrosAgent::Api::Unauthorized, CybrosAgent::Api::Forbidden, CybrosAgent::Api::NotFound => error
        @mutex.synchronize do
          @closed = true
          @valid_until = 0.0
        end
        unavailable(error, pending)
      rescue CybrosAgent::Error => error
        @mutex.synchronize do
          if %w[not_claimant not_found unauthorized forbidden not_authorized].include?(error.code.to_s)
            @closed = true
            @valid_until = 0.0
          end
        end
        delay = [POLL_SECONDS, error.retry_after || 0].max
        unavailable(error, pending)
      ensure
        if id
          @mutex.synchronize do
            @pending = nil if @pending.equal?(pending)
            # An uncertain offer has no confirmed generation to refresh. The
            # caller's next offer reconciles it before replacing it; reading
            # the old generation here would turn a lost response into refusal.
            @next_at = @closed || @stopped || (pending && !@snapshot) ? nil : @clock.call + delay
          end
        end
      end

      private

        def unavailable(error, pending)
          @log.warn("runner_realtime_unavailable", task: @task.task_key, code: error.code || error.class.name)
          @mutex.synchronize { @pending = nil if @pending.equal?(pending) }
          pending&.answer&.push(error: error)
        end
    end
  end
end
