require "async"

module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # Fixed native execution threads keep synchronous handlers off the control
    # reactor. Each thread hosts Async tasks, so a handler waiting for a child
    # keeps its stack and ownership while the same thread can start that child.
    # Kernel calls and deadline renewal remain on the calling control fiber.
    class Pool
      class Stopped < Error; end

      # One ticket per execution thread bounds work admitted but not yet started.
      # Async#async runs a new handler to its first wait or completion before
      # returning its ticket. Waiting handlers no longer hold admission capacity;
      # their existing control waits still enforce and renew each task deadline.
      # Resumed fibers may compute before a newly admitted job starts, so a ticket
      # promises a bounded startup backlog, not an idle thread at claim time.
      BACKLOG_PER_WORKER = 1
      # A cancellation allows this long for an answer and one reactor response.
      # A responsive handler may finish alone; only an unresponsive execution
      # thread is replaced. Neither kind is killed in the middle of an effect.
      CANCELLATION_GRACE_SECONDS = 2
      STOP = Object.new.freeze
      STARTED = Object.new.freeze
      private_constant :STOP, :STARTED

      Job = Struct.new(:context, :handler, :result, :worker, :ticket, keyword_init: true)
      Worker = Struct.new(:thread, :checks, keyword_init: true)
      private_constant :Job, :Worker

      attr_reader :worker_count

      def initialize(worker_threads:, grace_seconds: CANCELLATION_GRACE_SECONDS)
        @worker_count = Integer(worker_threads)
        raise ArgumentError, "worker_threads must be positive" unless @worker_count.positive?

        @grace_seconds = grace_seconds
        @available = Thread::Queue.new
        (@worker_count * BACKLOG_PER_WORKER).times { @available << Object.new.freeze }
        @pending = Thread::Queue.new
        @mutex = Mutex.new
        @accepting = true
        @running = {}
        @workers = []
        @mutex.synchronize { @worker_count.times { @workers << start_worker } }
      end

      # Non-blocking: nil when the pool is full, which is not an error. The
      # inbox is level-triggered, so the next pass IS the retry — and not
      # claiming leaves the row for a sibling runner that has room.
      def reserve
        return nil unless accepting?

        @available.pop(true)
      rescue ThreadError
        nil
      end

      def release(ticket)
        @available << ticket if ticket
        nil
      end

      # Runs `handler` on a worker and returns its value, raising whatever it
      # raised. The CALLING FIBER blocks on a queue rather than the reactor
      # thread spinning, so other fibers keep running.
      #
      # THE WAIT IS BOUNDED BY THE CONTEXT'S OWN CLOCK. A
      # deadline observed only at a handler's checkpoints was a courtesy:
      # a plugin that never asks, an echo that sleeps, parked to the
      # kernel's deadline, and the sweep wrote `uncertain` for a runner
      # that was alive the whole time — the word reserved for a claim
      # nobody answered. Waiting here is what makes "the runner clamps
      # every tool" true for every tool — and the wait is where the
      # context's ask for more time is made, on this fiber (the reactor's,
      # where the kernel call belongs), between slices.
      def run(ticket, context, &handler)
        queued = false
        token = Object.new
        job = Job.new(context: context, handler: handler,
          result: Thread::Queue.new, ticket: ticket)
        @mutex.synchronize do
          raise Stopped, "runner pool is stopped" unless @accepting

          @running[token] = job
          @pending << job
          queued = true
        end
        outcome = wait_for(job, context)
        raise outcome.fetch(:error) if outcome.key?(:error)

        outcome.fetch(:value)
      ensure
        @mutex.synchronize { @running.delete(token) } if token
        release(ticket) unless queued
      end

      # Stop admission and cancel every owned task before retiring execution
      # threads. A handler that ignores cancellation retains its resources until
      # its real exit; shutdown never interrupts an arbitrary synchronous write.
      def stop
        contexts = @mutex.synchronize do
          @accepting = false
          @running.values.map(&:context)
        end
        contexts.each { |context| context.cancel(:shutdown) }
        deadline = now + @grace_seconds
        sleep(0.05) while !@mutex.synchronize { @running.empty? } && now < deadline

        workers = @mutex.synchronize { @workers.dup }
        workers.each { |worker| retire_worker(worker) }
        workers.each { |worker| worker.thread.join(@grace_seconds) }
        nil
      end

      # A task key is local to its loop. Only that loop's matching context
      # is cancelled with `:canceled` (what `work_canceled` means; `stop`
      # says `:shutdown`), cooperatively, and the worker is kept — a
      # cancelled handler returns through its own checkpoint and the pool's
      # ordinary path. True when a context was found.
      def cancel(run_public_id:, task_key:)
        contexts = @mutex.synchronize do
          @running.values.map(&:context).select do |context|
            context.run_public_id == run_public_id && context.task_key == task_key
          end
        end
        contexts.each { |context| context.cancel(:canceled) }
        !contexts.empty?
      end

      def in_flight = @mutex.synchronize { @running.length }

      private

        def accepting? = @mutex.synchronize { @accepting }

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Slice by slice: the clamp, or the next ask, whichever is sooner. A
        # slice that ends with no answer and no deadline left is the clamp;
        # one that ends at an ask renews the context's deadline and waits again.
        def wait_for(job, context)
          loop do
            outcome = job.result.pop(timeout: context.wait_slice(extend: started?(job)))
            next if STARTED.equal?(outcome)
            return outcome if outcome

            remaining = context.remaining
            return clamp(job) if remaining && remaining <= 0

            context.renew!(extend: started?(job))
          end
        end

        def started?(job) = @mutex.synchronize { !job.worker.nil? }

        # The existing cancellation grace also tests the hosting reactor once.
        # A sleeping fiber which ignores its context does not occupy its native
        # thread; replacing that thread would grow capacity for ordinary waits.
        # A blocked native call cannot answer this queue, so it retains the old
        # safe abandonment behavior. An unstarted claim checks every host: its
        # initial grant bounds startup even if a host blocked after an earlier
        # response. This check has no timer or periodic work.
        def clamp(job)
          job.context.cancel(:deadline)
          workers = @mutex.synchronize { job.worker ? [job.worker] : @workers.dup }
          checks = workers.map { |worker| [worker, check_worker(worker)] }
          until_at = now + @grace_seconds
          loop do
            outcome = job.result.pop(timeout: [until_at - now, 0].max)
            next if STARTED.equal?(outcome)
            return outcome if outcome

            break
          end

          checks.each { |worker, response| abandon(worker) unless response&.pop(timeout: 0) }
          reason = job.context.reason
          message = reason == :deadline ? "execution deadline exceeded" : "execution cancelled"
          { error: ExecutionContext::Cancelled.new(message, reason: reason) }
        end

        def check_worker(worker)
          response = Thread::Queue.new
          worker.checks << response
          response
        rescue ClosedQueueError
          nil
        end

        # Several tasks can time out on one blocked thread. Replace that host
        # only once, cancel the other contexts it can no longer serve, and leave
        # their stacks and extension leases intact until their actual exit.
        def abandon(worker)
          jobs = @mutex.synchronize do
            if @accepting && @workers.include?(worker)
              replacement = start_worker
              @workers = @workers.reject { |candidate| candidate.equal?(worker) } + [replacement]
              @running.values.select { |job| job.worker.equal?(worker) }
            end
          end
          if jobs
            jobs.each do |job|
              job.context.cancel(:shutdown)
              release_startup(job)
            end
            retire_worker(worker)
          end
        end

        def retire_worker(worker)
          worker.checks << STOP
        rescue ClosedQueueError
          nil
        end

        def serving?(worker) = @mutex.synchronize { @workers.include?(worker) }

        # Normally the worker returns this after Async's first yield. A blocked
        # startup may be abandoned first; clearing the existing job field under
        # the pool mutex prevents its eventual return from duplicating a ticket.
        def release_startup(job)
          ticket = @mutex.synchronize do
            held = job.ticket
            job.ticket = nil
            held
          end
          release(ticket)
        end

        def start_worker
          worker = Worker.new(checks: Thread::Queue.new)
          worker.thread = Thread.new do
            Async do |reactor|
              intake = reactor.async do
                loop do
                  break unless serving?(worker)

                  job = @pending.pop
                  unless serving?(worker)
                    @pending << job
                    break
                  end

                  # Handlers are siblings of intake. Retiring only intake must
                  # never cancel a handler in the middle of a synchronous write.
                  reactor.async(job) { |_task, pending| pending.result << execute(pending, worker) }
                  release_startup(job)
                end
              end
              reactor.async do
                while response = worker.checks.pop
                  if STOP.equal?(response)
                    intake.stop
                    break
                  else
                    response << true
                  end
                end
              end
              intake.wait
            ensure
              worker.checks.close
            end.wait
          end
          worker
        end

        # The context is bound HERE, on the worker, because that is the
        # thread a handler's `raise_if_cancelled!` runs on. A job whose
        # context was cancelled before any worker reached it — the clamp
        # at zero remaining, a `stop` — is not run at all.
        def execute(job, worker)
          @mutex.synchronize { job.worker = worker }
          job.context.raise_if_cancelled!
          # A queued caller omits extension scheduling until this fact arrives.
          # Wake its existing result wait even when it has no other control IO.
          job.result << STARTED
          { value: ExecutionContext.with(job.context) { job.handler.call } }
        rescue Exception => error # rubocop:disable Lint/RescueException
          # A handler raising anything at all is that TASK's problem and never
          # the pool's: swallowing it here would hang the caller forever on
          # its result queue, and letting it escape would take the worker
          # down with it.
          { error: error }
        end
    end
  end
end
