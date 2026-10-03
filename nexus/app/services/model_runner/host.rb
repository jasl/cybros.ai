require "async"
require "async/condition"
require "pg"

module ModelRunner
  # The model runner: one Async reactor carries every provider stream, so
  # concurrency is bound by neither threads nor the pool. The rows are the
  # only queue, ProviderStart the only arbiter, and the sweeps own recovery.
  class Host
    HOST = "model_runner".freeze
    CLAIM_BATCH_LIMIT = 32
    TICK_INTERVAL = 0.5
    # `settled` is the in-process fact the tick reads: the stream said its
    # last word and the fiber is finishing (flip, wakes), so a cut would
    # only lose the wakes it still owes.
    InFlight = Struct.new(:attempt, :sink, :fiber, :settled, keyword_init: true)

    def initialize(
      max_in_flight: Integer(ENV.fetch("MODEL_RUNNER_MAX_IN_FLIGHT", 256)),
      shutdown_grace: Float(ENV.fetch("MODEL_RUNNER_SHUTDOWN_GRACE_SECONDS", 25)),
      logger: Rails.logger
    )
      @max_in_flight = max_in_flight
      @shutdown_grace = shutdown_grace
      @logger = logger
      @in_flight = {}
      @stopping = false
      @admission_dirty = false
      @work_condition = Async::Condition.new
      @admission_condition = Async::Condition.new
    end

    def stop = @stopping = true

    def run
      install_signal_traps
      Sync do |task|
        listener = task.async { listen_loop }
        ticker = task.async { tick_loop }
        admitter = task.async { admission_loop }
        @logger.info(
          "event=model_runner_started max_in_flight=#{@max_in_flight} " \
          "shutdown_grace_s=#{@shutdown_grace}"
        )

        claim_loop(task)
        drain_in_flight
      ensure
        [listener, ticker, admitter].compact.each { |loop_task| loop_task.stop if loop_task.running? }
        @logger.info("event=model_runner_stopped")
      end
    end

    private

      def install_signal_traps
        # Traps only flip the flag; the 0.5s ticker wakes every loop, so no
        # fiber machinery runs in signal context.
        %w[TERM INT].each { |signal| trap(signal) { @stopping = true } }
      end

      def claim_loop(task)
        until @stopping
          claimed = with_executor { claim_batch }
          claimed.each { |attempt| spawn_execution(task, attempt) }
          next if claimed.any?

          @work_condition.wait
        end
      end

      def claim_batch
        capacity = @max_in_flight - @in_flight.size
        return [] if capacity <= 0

        ModelInvocationAttempt
          .where(status: "prepared")
          .joins(:model_invocation)
          .where(model_invocations: { status: "running", workload: "text_generation" })
          .where.not(id: @in_flight.keys)
          .order(:id)
          .limit(capacity.clamp(..CLAIM_BATCH_LIMIT))
          .to_a
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error, context: { event: "model_runner_claim_error" })
        []
      end

      def spawn_execution(task, attempt)
        entry = InFlight.new(
          attempt: attempt,
          sink: ModelInvocations::StreamSink.for(attempt: attempt, host: HOST),
          settled: false
        )
        @in_flight[attempt.id] = entry

        task.async do
          entry.fiber = Fiber.current
          with_executor do
            ModelInvocations::ExecuteAttempt.call(
              attempt: attempt, host: HOST,
              stream_sink: entry.sink,
              settled: -> { entry.settled = true }
            )
          end
        rescue ExecutionAborted => error
          # The abort writes no row; the sink drops its pending tail, since
          # durable deltas already told the story up to the cut.
          entry.sink&.on_stream_canceled(attempt.model_invocation)
          @logger.info(
            "event=model_runner_execution_aborted attempt=#{attempt.public_id} " \
            "reason=#{error.message}"
          )
        rescue StandardError => error
          # One fiber's failure is one fiber's: the row is the sweeps' to
          # recover, and the backtrace is what makes that path diagnosable.
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "model_runner_execution_error", attempt: attempt.public_id })
        ensure
          @in_flight.delete(attempt.id)
          request_admission
          @work_condition.signal
        end
      end

      def tick_loop
        until @stopping
          sleep(TICK_INTERVAL)
          tick
          @work_condition.signal
        end
      end

      def tick
        with_executor { abort_cut_in_flight }
        request_admission
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error, context: { event: "model_runner_tick_error" })
      end

      # The kernel cuts the invocation and this host stops paying for its
      # stream; settling the row stays the converger's.
      def abort_cut_in_flight
        return if @in_flight.empty?

        cut_parent_ids = ModelInvocation
          .where(id: @in_flight.values.map { |entry| entry.attempt.model_invocation_id })
          .where(status: ModelInvocation::TERMINAL_STATUSES)
          .pluck(:id)
        return if cut_parent_ids.empty?

        @in_flight.each_value do |entry|
          next unless cut_parent_ids.include?(entry.attempt.model_invocation_id)
          # An attempt that settled its own parent is finishing, not cut:
          # the terminal the tick sees is this fiber's own, and its
          # post-terminal wakes must run — a raise here lands in the
          # enqueue's IO wait and the row waits for the recurring floor.
          next if entry.settled

          abort_in_flight(entry, ExecutionAborted.cancel)
        end
      end

      # Same mechanism Async::Task#stop uses internally: the scheduler raises
      # into the suspended fiber, which unwinds through the adapter's
      # cancel-safe request.
      def abort_in_flight(entry, error)
        fiber = entry.fiber
        return unless fiber&.alive?
        return if fiber == Fiber.current

        Fiber.scheduler.raise(fiber, error)
      rescue FiberError
        nil
      end

      # Single-flight admission, so a runner with no queue host attached
      # still self-feeds.
      def admission_loop
        until @stopping
          if @admission_dirty
            @admission_dirty = false
            run_admission_pass
            @work_condition.signal
          else
            @admission_condition.wait
          end
        end
      end

      def run_admission_pass
        with_executor do
          result = ModelInvocations::AdmitQueuedWork.call(lock_timeout_seconds: 0)
          ModelInvocations::AdmitQueuedWorkJob.perform_later if result.lock_contended?
        end
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error, context: { event: "model_runner_admission_error" })
      end

      def request_admission
        @admission_dirty = true
        @admission_condition.signal
      end

      # Dedicated raw LISTEN connection — never from the AR pool, whose
      # checkin would drop the registration — self-healing with a full claim
      # poll on every (re)connect.
      def listen_loop
        until @stopping
          begin
            with_listen_connection do |connection|
              @work_condition.signal
              until @stopping
                next unless connection.socket_io.wait_readable(1)

                connection.consume_input
                notified = false
                notified = true while connection.notifies
                @work_condition.signal if notified
              end
            end
          rescue PG::Error, IOError, SystemCallError => error
            Rails.error.report(error, handled: true, context: { event: "model_runner_listen_error" })
            sleep(1)
          end
        end
      end

      def with_listen_connection
        config = ActiveRecord::Base.connection_db_config.configuration_hash
        # pg serializes nil options as empty strings, overriding libpq's PGHOST,
        # PGUSER and PGPASSWORD defaults used by deployments with discrete env.
        connection = PG.connect(**{
          host: config[:host], port: config[:port], dbname: config[:database],
          user: config[:username], password: config[:password],
        }.compact)
        connection.exec("LISTEN #{ModelInvocations::Wake::NOTIFY_CHANNEL}")
        yield connection
      ensure
        connection&.close
      end

      # In-flight streams get the grace to finish; survivors are aborted
      # and go to the deadline sweep, never requeued free — a started attempt may be billed.
      def drain_in_flight
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @shutdown_grace
        sleep(0.1) while @in_flight.any? &&
          Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        @in_flight.each_value { |entry| abort_in_flight(entry, ExecutionAborted.shutdown) }
        grace = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep(0.1) while @in_flight.any? &&
          Process.clock_gettime(Process::CLOCK_MONOTONIC) < grace
      end

      def with_executor(&block)
        Rails.application.executor.wrap(&block)
      end
  end
end
