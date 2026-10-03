module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # A small local execution substrate for BLOCKING tool handlers.
    #
    # WHY IT EXISTS AT ALL: rho has one Async reactor, and `OneShotRun` needs
    # no more than that because following a run is pure IO wait. A tool is
    # not — reading a file and running a shell command block the OS thread,
    # and blocking the reactor would stall every other fiber on it, the
    # claim and submit calls included. So handlers run on fixed native
    # threads and ONLY the handler does; every kernel call stays on the
    # reactor.
    #
    # ADMISSION IS RESERVED BEFORE THE CLAIM. A ticket is taken first, and
    # only then does the runner ask the kernel for the work. Under a
    # protocol with no heartbeat this ordering is not politeness: a claim
    # held while queueing burns the park's own deadline with no way to
    # extend it, and the row silently returns to the pool mid-wait.
    class Pool
      class Stopped < Error; end

      # ONE TICKET PER WORKER, and that is the whole admission rule. A
      # ticket is taken BEFORE the claim precisely so a claim is never
      # held while queueing — the park's clock runs from the claim. The
      # predecessor's four-per-worker backlog broke that promise: a claimed
      # task could wait behind three others with its deadline burning,
      # which nothing reached while nudges ran one at a time and everything
      # reaches now that they fan out. A runner that is full declines, and
      # the sweep offers the row again in five seconds — to this runner or
      # to a sibling with a free worker, which is the better outcome anyway.
      BACKLOG_PER_WORKER = 1
      # How long a cancelled handler is given to notice before its thread is
      # abandoned and replaced. Cooperative cancellation cannot be forced.
      CANCELLATION_GRACE_SECONDS = 2
      STOP = Object.new.freeze
      private_constant :STOP

      # `taken` is where the worker that picked the job up names itself, so
      # a clamp knows which thread to abandon.
      Job = Data.define(:context, :handler, :result, :taken)
      private_constant :Job

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
        @workers = Array.new(@worker_count) { start_worker }
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
        raise Stopped, "runner pool is stopped" unless accepting?

        # REGISTERED BEFORE IT IS QUEUED, so a `stop` racing this call
        # cancels a context that has not reached a worker yet rather than
        # missing it and waiting out the grace window for nothing.
        token = Object.new
        @mutex.synchronize { @running[token] = context }
        job = Job.new(context: context, handler: handler,
          result: Thread::Queue.new, taken: Thread::Queue.new)
        @pending << job
        outcome = wait_for(job, context)
        raise outcome.fetch(:error) if outcome.key?(:error)

        outcome.fetch(:value)
      ensure
        @mutex.synchronize { @running.delete(token) } if token
        release(ticket)
      end

      # Cooperative, then abandoning. A handler that ignores its context is
      # given the grace window and then its thread is left to finish alone
      # while a replacement takes its place — a wedged tool must not cost
      # the runner a worker forever, and it must not be killed either, since
      # Thread#kill mid-write is how a half-written file happens.
      def stop
        contexts = @mutex.synchronize do
          @accepting = false
          @running.values.dup
        end
        contexts.each { |context| context.cancel(:shutdown) }
        deadline = now + @grace_seconds
        sleep(0.05) while !@mutex.synchronize { @running.empty? } && now < deadline

        @worker_count.times { @pending << STOP }
        @mutex.synchronize { @workers.dup }.each { |worker| worker.join(@grace_seconds) }
        nil
      end

      # A task key is local to its loop. Only that loop's matching context
      # is cancelled with `:canceled` (what `work_canceled` means; `stop`
      # says `:shutdown`), cooperatively, and the worker is kept — a
      # cancelled handler returns through its own checkpoint and the pool's
      # ordinary path. True when a context was found.
      def cancel(agent_loop_public_id:, task_key:)
        contexts = @mutex.synchronize do
          @running.values.select do |context|
            context.agent_loop_public_id == agent_loop_public_id && context.task_key == task_key
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
            outcome = job.result.pop(timeout: context.wait_slice)
            return outcome if outcome

            remaining = context.remaining
            return clamp(job) if remaining && remaining <= 0

            context.renew!
          end
        end

        # THE DEADLINE PASSED WITH NO ANSWER. Cancel with the deadline
        # reason — the kill callbacks fire NOW (`bash`'s group dies, not
        # at its next poll) and a cooperative handler returns through its
        # own checkpoint inside the grace. One that still has not answered
        # is ABANDONED: its worker is replaced and its thread finishes
        # alone, never killed (`stop`'s rule — Thread#kill mid-write is how
        # a half-written file happens). Either way the caller gets the
        # deadline, by reason, and the task run answers it as data.
        def clamp(job)
          job.context.cancel(:deadline)
          outcome = job.result.pop(timeout: @grace_seconds)
          return outcome if outcome

          abandon(job.taken.pop(timeout: 0))
          { error: ExecutionContext::Cancelled.new("execution deadline exceeded", reason: :deadline) }
        end

        # nil when no worker had taken the job yet: nothing to replace, and
        # the worker that reaches it later finds its context cancelled.
        def abandon(worker)
          return if worker.nil?

          replacement = start_worker
          @mutex.synchronize do
            @workers = @workers.reject { |candidate| candidate.equal?(worker) } + [replacement]
          end
        end

        def serving?(thread) = @mutex.synchronize { @workers.any? { |worker| worker.equal?(thread) } }

        def start_worker
          Thread.new do
            loop do
              job = @pending.pop
              break if STOP.equal?(job)

              job.result << execute(job)
              # An abandoned worker finishes the job it was replaced over
              # and stops; its replacement is the one serving now.
              break unless serving?(Thread.current)
            end
          end
        end

        # The context is bound HERE, on the worker, because that is the
        # thread a handler's `raise_if_cancelled!` runs on. A job whose
        # context was cancelled before any worker reached it — the clamp
        # at zero remaining, a `stop` — is not run at all.
        def execute(job)
          job.taken << Thread.current
          job.context.raise_if_cancelled!
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
