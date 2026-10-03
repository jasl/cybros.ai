require "etc"
require "monitor"
require "time"
require "cybros_agent"

require_relative "runner/version"
require_relative "runner/errors"
require_relative "runner/truncation"
require_relative "runner/file_mutation_queue"
require_relative "runner/tool_env"
require_relative "runner/environment"
require_relative "runner/owned_process"
require_relative "runner/redact"
require_relative "runner/secrets"
require_relative "runner/child_env"
require_relative "runner/subprocess"
require_relative "runner/tools/read"
require_relative "runner/tools/write"
require_relative "runner/tools/edit"
require_relative "runner/tools/ls"
require_relative "runner/tools/grep"
require_relative "runner/tools/find"
require_relative "runner/tools/bash"
require_relative "runner/files"
require_relative "runner/tools/files_bytes"
require_relative "runner/tools/file_import"
require_relative "runner/tools/file_publish"
require_relative "runner/skills"
require_relative "runner/tools/skill"
require_relative "runner/checkpoints/record"
require_relative "runner/checkpoints/git"
require_relative "runner/checkpoints/store"
require_relative "runner/tools/world_restore"
require_relative "runner/tools/checkpoints"
require_relative "runner/execution_context"
require_relative "runner/fs_port"
require_relative "runner/deadline_extension"
require_relative "runner/claim_status_poller"
require_relative "runner/claim_attachments"
require_relative "runner/progress"
require_relative "runner/result"
require_relative "runner/storable_text"
require_relative "runner/pool"
require_relative "runner/extensions/tool"
require_relative "runner/extensions/hooks"
require_relative "runner/extensions/api"
require_relative "runner/extensions/registry"
require_relative "runner/extensions/loader"
require_relative "runner/input_schema"
require_relative "runner/toolset"
require_relative "runner/placement"
# AFTER `toolset`, because the built-ins' own extension names the tool
# classes and the registry that will hold them.
require_relative "runner/extensions/coding/report"
require_relative "runner/extensions/coding"
require_relative "runner/extensions/checkpoints"
# AFTER the extensions: `Toolsets.fixed` builds the coding set.
require_relative "runner/toolsets"
require_relative "runner/task_run"

module Rho
  # THE RUNNER: parked tool work, taken and answered.
  #
  # TWO ENTRANCES, ONE TRUTH. A realtime nudge names a loop, a task key and a
  # tool name and carries nothing executable, so it is pure latency — it lets
  # a runner claim that one task directly and never list. The INBOX is the
  # truth: a level-triggered sweep that a runner which slept, crashed,
  # restarted or missed every frame recovers from completely. Both converge
  # on the same door. Active executions also read their exact claim while
  # waiting, so a missed cancellation is recovered without another sweep.
  #
  # It is OneShotRun-shaped — a fiber on the control server's reactor, state
  # under one monitor, an injectable sleeper so tests do not wait — and
  # departs in exactly one place: following a run is pure IO wait, while a
  # tool blocks the OS thread, so handlers go to a bounded native pool and
  # only the kernel calls stay on the reactor.
  class Runner
    # THE PROGRAM'S ROOT: the directory this gem is loaded from — a checkout in development,
    # the installed gem in production — which rho's self-modification deny rules protect
    # beside its own: the toolset gem is the program too.
    def self.root = File.expand_path("../..", __dir__)

    # The recovery cadence, not the latency budget. The cable is what makes
    # work start promptly; this only has to be fast enough that a runner
    # which missed every frame does not sit idle for long.
    SWEEP_SECONDS = 5.0
    # One page per pass bounds polling work. The cursor advances past claimed
    # and human-held rows, then wraps so unclaimed work is offered again.
    PAGE_LIMIT = 50
    # The one inbox kind a runner answers; the rest are the agent's.
    TOOL_CALL_KIND = "tool_call".freeze

    # `nudged` and `swept` are two meters on purpose, and the pair is the
    # diagnosis: a runner doing work with `nudged: 0` is being carried
    # entirely by its own polling, which is the product WORKING and the
    # latency path BROKEN. Nothing else can tell those apart from outside.
    # `canceled` counts the in-flight contexts a `work_canceled` frame
    # reached — the kernel's cancel meeting this runner's answer.
    Snapshot = Data.define(:running, :in_flight, :claimed, :swept, :nudged, :canceled, :tools) do
      def to_h
        { running:, in_flight:, claimed:, swept:, nudged:, canceled:, tools: }
      end
    end

    # `executor` is the SDK's `ExecutorClient` — this address's own inbox
    # on the executor plane (`inbox.list`, `inbox_task(...)`), the one
    # plane a runner holds. `toolsets` answers each
    # claimed row's PLACEMENT (`Toolsets`: the conversation's env and
    # toolset, resolved on the worker; `Toolsets.fixed` for one placement).
    # `hooks` is the extension plane's tool-call chain. Absent means an
    # empty host, so a runner assembled without extensions costs nothing
    # per call and reads the same either way.
    def initialize(executor:, toolsets:, log:, pool: nil, sleeper: nil, hooks: nil)
      @executor = executor
      @toolsets = toolsets
      @log = log
      @pool = pool || Pool.new(worker_threads: default_workers)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @task_run = TaskRun.new(
        executor: executor, pool: @pool, toolsets: toolsets, log: log,
        hooks: hooks || Extensions::Hooks::Host.new, sleeper: @sleeper,
        on_cancel: ->(reason) { @monitor.synchronize { @canceled += 1 } if reason == :canceled }
      )
      @monitor = Monitor.new
      @stopping = false
      @claimed = 0
      @swept = 0
      @sweep_after = nil
      @nudged = 0
      @canceled = 0
      @answering = 0
    end

    def snapshot
      @monitor.synchronize do
        Snapshot.new(running: !@stopping, in_flight: @pool.in_flight,
          claimed: @claimed, swept: @swept, nudged: @nudged, canceled: @canceled,
          tools: @toolsets.names)
      end
    end

    # The fiber body. Level-triggered and safe to run at any time: a pass
    # that finds nothing does nothing.
    def follow
      until stopping?
        sweep
        @sleeper.call(SWEEP_SECONDS)
      end
    end

    # ONE EPHEMERAL FRAME on this address's plane (executor.md "Progress"),
    # for a producer OUTSIDE a task run — the daemon's process pump posting
    # `process_output` under a host this runner is bound to. The frame is
    # the caller's whole; the kernel's fence and cadence are the answer.
    def report_progress(frame) = @executor.report_progress(frame)

    # A nudge from the cable. It names WHICH task, so this takes exactly that
    # one and never lists — the claim IS the fetch.
    def nudged(agent_loop_public_id:, task_key:, tool_name: nil)
      return if stopping? || task_key.nil? || agent_loop_public_id.nil?

      @monitor.synchronize { @nudged += 1 }
      take(agent_loop_public_id: agent_loop_public_id, task_key: task_key,
        tool_name: tool_name)
    end

    # A cancel from the cable names the loop and its task key; keys repeat
    # across loops. The matching context is cancelled cooperatively — the
    # handler notices at its next checkpoint, `bash` kills its process
    # group, and the claim is answered `failed` interrupted. True when a
    # running context was found; a key nobody holds is not an error (the
    # row may have finished, or never been ours).
    def cancel(agent_loop_public_id:, task_key:)
      @pool.cancel(agent_loop_public_id: agent_loop_public_id, task_key: task_key)
    end

    # How long a stop waits for answers already on their way to the
    # kernel. The pool's stop waits for HANDLERS to return; the fiber that
    # ran one then submits the answer, and a reactor interrupted before
    # that POST lands leaves the task claimed to its park deadline —
    # unreachable by the restarted daemon, which is refused as
    # `already_claimed`. Bounded, because an answer that cannot land in
    # this long is not going to.
    ANSWER_WAIT_SECONDS = 10.0

    def stop(answer_wait: ANSWER_WAIT_SECONDS)
      @monitor.synchronize { @stopping = true }
      @pool.stop
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + answer_wait
      while answering? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.02
      end
      nil
    end

    def answering? = @monitor.synchronize { @answering.positive? }

    private

      def stopping? = @monitor.synchronize { @stopping }

      # Bounded by what the machine can actually run at once, because a tool
      # is CPU and IO on this host rather than a request to somewhere else.
      def default_workers
        [[Etc.nprocessors, 2].max, 8].min
      rescue StandardError
        4
      end

      # THE RECOVERY PASS. One page in arrival order, resuming the previous
      # cursor and wrapping after the last page. A ROW ADDRESSED TO ME IS
      # ONE I ANNOUNCED:
      # the kernel addresses work by this address's own announcement, so
      # there is no local "do I serve this?" filter — what is listed is
      # taken. A claimed row is listed too — a runner returning from a
      # crash must see the work it already holds — and is left alone: its
      # holder's deadline is the only thing that releases it.
      # A ROW OF ANOTHER KIND IS NOT THE RUNNER'S: an `ask` is
      # the agent application's to answer — listed on the same inbox for
      # its addressee, never claimed — and a word this runner does not know
      # is carried, never taken; both are left where they stand rather than
      # claimed and refused `not_claimable_kind` every pass.
      # THE PASS IS COUNTED, NOT THE SUCCESS. An operator reading `swept: 0`
      # should learn "the loop is not running", never "the inbox is
      # unreachable" — those want different answers, and counting only what
      # succeeded reports the second as the first.
      def sweep
        @monitor.synchronize { @swept += 1 }
        page = @executor.inbox.list(after: @sweep_after, limit: PAGE_LIMIT)
        @sweep_after = page.next_after
        page.items.each do |task|
          break if stopping?
          next unless takeable?(task)

          take(agent_loop_public_id: task.agent_loop_public_id,
            task_key: task.task_key, tool_name: task.tool_name)
        end
      rescue CybrosAgent::Api::Unauthorized
        lose_authority
      rescue CybrosAgent::Error => error
        # The inbox being unreachable is a condition to wait out, not to
        # crash on: the next pass is five seconds away and the work is
        # still there.
        @log.warn("runner_sweep_failed", error_class: error.class.name)
      end

      # Unclaimed, and a tool call.
      def takeable?(task)
        !task.claimed? && task.kind == TOOL_CALL_KIND
      end

      # A 401 ON THE EXECUTOR PLANE IS TERMINAL FOR THE RUNNER HALF: the transport credential stopped being usable — a re-pair, a
      # revoke, a family loss — and the executor plane has no rotation, so
      # no retry can change the answer. The runner stops taking work, says
      # so once, and starts NO ceremony of its own: a runner "must not
      # automatically begin another device flow" (executor.md). Reconnecting
      # is the operator's, through the daemon.
      def lose_authority
        @monitor.synchronize { @stopping = true }
        @log.warn("runner_authority_lost",
          detail: "the executor credential is no longer accepted; the runner stopped")
      end

      # ANY error is this runner's to log, not only the SDK's: under
      # per-fiber dispatch a raise here ends one fiber that nothing else
      # reads, and the daemon's log was the only place it could be seen —
      # it was not. A process-fatal exception is not an error and passes.
      def take(agent_loop_public_id:, task_key:, tool_name:)
        @monitor.synchronize { @answering += 1 }
        outcome = @task_run.call(agent_loop_public_id: agent_loop_public_id,
          task_key: task_key, tool_name: tool_name)
        @monitor.synchronize { @claimed += 1 } if outcome == :done
        outcome
      rescue StandardError => error
        @log.warn("runner_task_failed", task: task_key, error_class: error.class.name,
          error: CybrosAgent::Redaction.call(error.message))
        nil
      ensure
        @monitor.synchronize { @answering -= 1 }
      end
  end
end
