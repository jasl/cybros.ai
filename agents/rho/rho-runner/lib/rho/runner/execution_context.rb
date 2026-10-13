module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # The only runtime state a tool handler receives. It carries no
    # client, no transport and no daemon reference on purpose: a worker may
    # OBSERVE cancellation, and every kernel call stays on the reactor.
    #
    # ONE CLOCK, AND IT IS THE SERVER'S. The predecessor carried two — a
    # local deadline and a renewable lease — because its protocol had
    # heartbeats. Ours has none: a park's deadline is minted server-side, and
    # the one thing a runner may do to it is ASK THE KERNEL TO MOVE IT
    # (`extension`, executor.md "Extend") — the same number, moved forward
    # by the kernel's answer, never a second timer beside it — so there is
    # exactly one number here and no way to resurrect a context that has
    # passed it.
    class ExecutionContext
      # WHY carries with the exception, because the runner answers the
      # three reasons differently: an ordinary tool's `:deadline` is DATA
      # the model reads (`completed, is_error` "timed out"). `:canceled`
      # (the kernel's `work_canceled`) and `:shutdown` (the runner
      # draining) stay `failed` interrupted.
      class Cancelled < Error
        attr_reader :reason

        def initialize(message = nil, reason: nil)
          super(message)
          @reason = reason
        end
      end

      # Thread#[] is fiber-local: waiting handlers share an execution thread,
      # but their task ownership and cancellation must never follow a sibling.
      CURRENT_KEY = :rho_runner_execution_context
      private_constant :CURRENT_KEY

      class << self
        def current = Thread.current[CURRENT_KEY]

        def with(context)
          previous = current
          Thread.current[CURRENT_KEY] = context
          yield
        ensure
          Thread.current[CURRENT_KEY] = previous
        end

        # The one door to the cancel-signal primitive, which stays private
        # because a callback fires on whichever thread requests cancellation.
        # It must do nothing but terminate an already-spawned OS resource —
        # never block, never run arbitrary work. With no active context the
        # block still runs and cancellation is simply unobservable.
        def with_cancel_signal(on_cancel)
          unregister = current&.send(:register_cancel_signal, &on_cancel)
          yield
        ensure
          unregister&.call
        end
      end

      # WHOSE WORK THIS IS. A tool that holds a resource across calls — a
      # browser tab, a shell session — needs to know which loop's calls
      # belong together, and the only place that is known on the worker
      # thread is here. Both are nil for a context built outside a task
      # (a test, a standalone probe), and a tool treats nil as "the one
      # default owner" rather than as an error.
      # `extension` is the timed ask for more time (`DeadlineExtension`),
      # present only for a handler with no clamp of its own; the pool's wait
      # consults it (`wait_slice`, `renew!`) and never the handler.
      # `conversation_public_id` is the loop's conversation as EVERY inbox
      # row names it (the process lifecycle follows the conversation) — nil for a standalone loop, which is its own host, and
      # outside a task; a tool that holds a resource across calls owns it
      # by this, the loop being display.
      # `workspace_public_id` is the task's execution container, independent
      # of an agent application's current default or followed hosts.
      # `scope` is the kernel's stamp on an externally served kernel row.
      # Memory overrides receive named database `bindings` with access modes;
      # source-routed skills receive the host's workspace/conversation/user IDs.
      # Other rows and calls outside a task have no stamp. A memory provider
      # keys its store by the supplied anchors, never by guessed defaults.
      # `claim_token` is the claim's own proof, carried so a running tool's
      # progress frames are keyed by it (executor.md "Progress"); `progress`
      # is the timed poster of those frames (`Progress`), fed by the handler
      # through `report_progress` and flushed by the pool's wait on the
      # reactor — the extension's model, for the other direction.
      # `tool_env`/`binding` are THE PLACEMENT: the
      # frozen env the row's tools run under and the conversation's
      # resolved record (nil at placement zero), set ONCE by the run inside
      # the pool block before the `tool_call` chain (`place`) — the hook
      # chain's view: rho's Guard resolves a relative path through the env,
      # the capture hook reads its store. nil outside a run; a test hands
      # them in here.
      # `orchestration` is the task-scoped mailbox for child operations and
      # observations. The handler retains its live state while waiting; the
      # control reactor performs queued SDK operations during `renew!`.
      # `ports` is THE PORTS RESOLVER: the
      # daemon's table of editor ports keyed by anchor, handed through the
      # toolsets and placed here with the placement; `port` looks it up
      # PER CALL by the binding's anchor, so nothing frozen holds a socket
      # and a port dropped between two calls is gone at the second. nil
      # for a host with no table (a fixed placement, a bare runner).
      def initialize(deadline: nil, run_public_id: nil, conversation_public_id: nil, task_key: nil,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, extension: nil, scope: nil,
                     claim_token: nil, progress: nil, tool_env: nil, binding: nil, ports: nil,
                     claim_poller: nil, on_cancel: nil, workspace_public_id: nil, attachments: nil, orchestration: nil)
        @deadline = deadline
        @run_public_id = run_public_id
        @conversation_public_id = conversation_public_id
        @workspace_public_id = workspace_public_id
        @task_key = task_key
        @clock = clock
        @extension = extension
        @scope = scope
        @claim_token = claim_token
        @progress = progress
        @claim_poller = claim_poller
        @attachments = attachments
        @orchestration = orchestration
        @on_cancel = on_cancel
        @tool_env = tool_env
        @binding = binding
        @ports = ports
        @placed = !tool_env.nil? || !binding.nil? || !ports.nil?
        @mutex = Mutex.new
        @cancelled = false
        @reason = nil
        @callbacks = []
      end

      attr_reader :deadline, :run_public_id, :conversation_public_id, :task_key, :extension, :scope,
        :claim_token, :progress, :tool_env, :binding, :workspace_public_id, :attachments, :orchestration

      # THE ONE PLACEMENT, once: the run resolves the row's placement on the
      # worker and sets it here before any hook runs; a second placement is
      # a caller bug — two truths on one context — and is refused.
      def place(tool_env:, binding:, ports: nil)
        @mutex.synchronize do
          raise ArgumentError, "the context is already placed under #{@tool_env&.root.inspect}" if @placed

          @placed = true
          @tool_env = tool_env
          @binding = binding
          @ports = ports
        end
        nil
      end

      # THE EDITOR'S PORT FOR THIS ROW, looked up now: the resolver asked
      # with the binding's anchor on every call — a context with no
      # anchor (placement zero, a standalone loop) or no resolver asks
      # nothing and answers nil, which is the disk.
      def port
        ports, anchor = @mutex.synchronize { [@ports, @binding&.anchor] }
        return nil if ports.nil? || anchor.nil?

        ports.call(anchor)
      end

      # FROM THE HANDLER'S THREAD: the latest tail of what the tool is
      # doing, for the pool's wait to post under this claim when the
      # cadence allows. Nothing is sent here; a context built outside a
      # task (no poster) takes the tail and drops it.
      def report_progress(text)
        @progress&.tail(text)
        nil
      end

      # What is left on the one clock, floored at zero; nil with no
      # deadline (the task has no clock at all). The pool waits on this,
      # which is what makes the clamp a rule rather than a
      # courtesy a handler pays at its checkpoints.
      def remaining
        return nil if @deadline.nil?

        [@deadline - @clock.call, 0].max
      end

      # How long the pool may wait before it must look again: the clamp,
      # the next ask, or the next pending frame, whichever is sooner; nil
      # when none is coming and the wait is the handler's own.
      # Startup backlog keeps its first grant; only an executing handler may
      # ask for another. Other control work remains scheduled while it queues.
      def wait_slice(extend: true)
        return remaining if cancelled?

        now = @clock.call
        renewal = @extension&.wait(now) if extend
        waits = [remaining, renewal, @progress&.wait(now), @claim_poller&.wait(now), @attachments&.wait, @orchestration&.wait].compact
        waits.empty? ? nil : waits.min
      end

      # Asks for more time when the ask is due, and moves the one deadline
      # by the kernel's answer; posts the pending progress frame when the
      # cadence allows. Called by the pool's wait on the reactor's fiber,
      # where the kernel calls belong; a handler never calls it.
      def renew!(extend: true)
        return if cancelled?

        cancel(:canceled) if @claim_poller&.poll == false
        return if cancelled?

        now = @clock.call
        @progress&.flush(now)
        @attachments&.flush
        @orchestration&.flush
        return if cancelled?
        return unless extend && @extension&.due?(@clock.call)

        deadline = @extension.call
        extend_deadline(deadline) if deadline
      end

      # Only forward, never over a cancellation: a context that passed its
      # deadline is cancelled and stays so; a later answer cannot revive it.
      def extend_deadline(deadline)
        @mutex.synchronize do
          return false if @cancelled || (@deadline && deadline <= @deadline)

          @deadline = deadline
        end
        true
      end

      def reason = @mutex.synchronize { @reason }

      def cancelled?
        callbacks, cancelled = @mutex.synchronize do
          [cancel_if_expired_locked(@clock.call), @cancelled]
        end
        invoke_cancel_callbacks(callbacks)
        cancelled
      end

      def raise_if_cancelled!
        return unless cancelled?

        why = reason
        raise Cancelled.new(why == :deadline ? "execution deadline exceeded" : "execution cancelled", reason: why)
      end

      # Requested by the reactor when the runner is draining. Cooperative:
      # a handler notices at its next checkpoint, and a signal terminates
      # whatever OS resource it had already spawned.
      def cancel(reason = :cancelled)
        callbacks = @mutex.synchronize { commit_cancellation_locked(reason) }
        return false if callbacks.nil?

        invoke_cancel_callbacks(callbacks)
        true
      end

      private

        def register_cancel_signal(&callback)
          raise ArgumentError, "register_cancel_signal requires a block" unless callback

          entry = [Object.new.freeze, callback].freeze
          invoke_now = @mutex.synchronize do
            @cancelled ? true : (@callbacks << entry) && false
          end
          invoke_callback(callback) if invoke_now
          -> { @mutex.synchronize { @callbacks.delete(entry) }; nil }
        end

        # The due-deadline observation and the cancellation transition are
        # ONE mutex-linearized operation, so a context cannot be observed
        # live and then cancelled between the check and the act. Callbacks
        # always run after the unlock.
        def cancel_if_expired_locked(now)
          return if @cancelled
          return unless @deadline && now >= @deadline

          commit_cancellation_locked(:deadline)
        end

        def commit_cancellation_locked(reason)
          return if @cancelled

          @cancelled = true
          @reason = reason
          @callbacks.shift(@callbacks.length)
        end

        def invoke_cancel_callbacks(callbacks)
          return if callbacks.nil?

          callbacks.each { |_token, callback| invoke_callback(callback) }
          @on_cancel&.call(@reason)
          nil
        end

        def invoke_callback(callback)
          callback.call
        rescue StandardError
          nil
        end
    end
  end
end
