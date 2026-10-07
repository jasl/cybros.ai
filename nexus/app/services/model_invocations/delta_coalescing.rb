module ModelInvocations
  # The first fragment appends immediately, the rest buffer to a window or
  # a byte bound, and a key switch flushes first to keep order (`empty?`,
  # never `blank?`). A timer flush failure re-raises on the next sink callback.
  #
  # THE WINDOW STAYS PENDING UNTIL ITS APPEND RETURNS, and one fiber flushes
  # it at a time. The reactor timer's append is a round trip the pump can
  # land inside: with the window cleared on the way in, a `response.completed`
  # arriving there found nothing to settle, ApplyResult committed the
  # terminal status, and the timer's gated append was refused — leaving the reply
  # short by its last window. So the pump joins a timer flush
  # in flight before it places a fragment or settles, and the timer leaves a
  # pump flush alone. Durable state decides; the join is only the ordering.
  module DeltaCoalescing
    DEFAULT_FLUSH_INTERVAL_MS = Integer(ENV.fetch("MODEL_RUNNER_DELTA_FLUSH_INTERVAL_MS", 100))
    DEFAULT_FLUSH_BYTES = Integer(ENV.fetch("MODEL_RUNNER_DELTA_FLUSH_BYTES", 4096))

    FlushError = Class.new(StandardError)

    def initialize_delta_coalescing(
      flush_interval_ms: DEFAULT_FLUSH_INTERVAL_MS,
      flush_bytes: DEFAULT_FLUSH_BYTES,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      @delta_flush_interval = flush_interval_ms / 1000.0
      @delta_flush_bytes = flush_bytes
      @delta_clock = clock
      @pending_delta = nil
      @last_delta_flush_at = nil
      @pending_flush_error = nil
    end

    def coalesce_delta(key, text)
      raise_pending_flush_error
      return if text.empty?
      return append_coalesced_delta(key, text) if @delta_flush_interval <= 0

      join_timer_flush
      now = @delta_clock.call
      flush_pending_delta if @pending_delta && @pending_delta[:key] != key

      if @pending_delta
        @pending_delta[:buffer] << text
        if now - @pending_delta[:started_at] >= @delta_flush_interval ||
            @pending_delta[:buffer].bytesize >= @delta_flush_bytes
          flush_pending_delta
        end
      elsif @last_delta_flush_at.nil? || now - @last_delta_flush_at >= @delta_flush_interval
        @last_delta_flush_at = now
        append_coalesced_delta(key, text)
      else
        pending = { key: key, buffer: +"" << text, started_at: now, flushing: false, timer: nil }
        @pending_delta = pending
        schedule_pending_delta_flush(pending)
      end
    end

    # The pump's flush — a key switch, an aged or fat buffer, the settle. A
    # window the timer is already appending is waited for, so the settle
    # returns only once the last window is durable.
    def flush_pending_delta
      join_timer_flush
      pending = @pending_delta
      return if pending.nil?

      flush(pending)
    end

    # The abort path: an in-flight timer append is left to land or be
    # refused — the discard says the pump no longer cares which, and puts
    # no wait on the way out.
    def discard_pending_delta
      @pending_delta = nil
    end

    # The retry path: the rollback marker that follows must come AFTER every
    # delta of this attempt that will land, so a timer append in flight is
    # joined first (the pump's own fiber, before ApplyResult), then the rest
    # of the window is dropped.
    def abandon_pending_delta
      join_timer_flush
      @pending_delta = nil
    end

    private

      # Whoever flushes marks the window theirs, and the window clears only
      # after the append returned — a fragment or a settle arriving inside
      # the round trip still finds it pending.
      def flush(pending)
        pending[:flushing] = true
        @last_delta_flush_at = @delta_clock.call
        append_coalesced_delta(pending[:key], pending[:buffer])
      ensure
        @pending_delta = nil if @pending_delta.equal?(pending)
      end

      # A pump-side caller finds `flushing` set only by the timer (its own
      # flushes are synchronous), so the join is the timer task's wait. The
      # timer's stashed failure surfaces to the caller that joined it.
      def join_timer_flush
        pending = @pending_delta
        return unless pending && pending[:flushing]

        pending[:timer]&.wait
        raise_pending_flush_error
      end

      # The timer's races are against the pump, checked by identity and by
      # ownership: a flushed or discarded pending is no longer @pending_delta,
      # and one the pump is flushing is the pump's to finish.
      def schedule_pending_delta_flush(pending)
        # `async` loads lazily with the adapter (require: false): a process
        # that never entered a reactor has no timer to schedule and no
        # constant to name it with.
        task = defined?(Async::Task) ? Async::Task.current? : nil
        return if task.nil?

        pending[:timer] = task.async(transient: true, annotation: "model invocation delta flush timer") do
          sleep(@delta_flush_interval)
          flush(pending) if @pending_delta.equal?(pending) && !pending[:flushing]
        rescue StandardError => error
          @pending_flush_error = error
        end
      end

      def raise_pending_flush_error
        error = @pending_flush_error
        return if error.nil?

        @pending_flush_error = nil
        raise FlushError, "delta flush timer failed: #{error.class}: #{error.message}"
      end
  end
end
