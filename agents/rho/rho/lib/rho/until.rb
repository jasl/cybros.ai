require "digest"
require "time"

module Rho
  # A COMPLETION PREDICATE THE MODEL CANNOT ARGUE WITH. `rho do PROMPT
  # --until "bin/rails test"`: the model works, ends its turn, and the
  # command is run FOR it; exit 0 closes the run with a summary round,
  # anything else hands the model the output and another attempt, up to
  # a count. Codex and claude-code both offer this shape (a checker the
  # harness runs, not the model), and both found the same thing: a model
  # told "the tests must pass" mostly says they do; a model shown the
  # failing output mostly fixes them.
  #
  # THE CHECK IS A BASH TOOL STEP ON THE BOUND RUNNER. It is placed by position after the attempt's round — `check-N`,
  # `{tool: bash, input: {command, workdir, timeout}, on_failure: absorb}`
  # — and the kernel's one addressing site sends it to the host's runner:
  # this machine's own in full mode, or a runner elsewhere, so the check
  # runs where the tree is. Its verdict is the settled row's `exit_status`
  # (bash's structured content), read once through the run's single-task
  # door; its output is the row's result, which the next round names in
  # its `results:` beside the hold and reads as the envelope ahead of its
  # prompt — a later append reaches an earlier one's row only by its key,
  # never by position. Nothing is copied into a prompt or spilled to a
  # local file. Nothing runs in this process.
  #
  # THE HOLD IS THE ASK behind the check — `hold-N`, a tokenless await the
  # daemon itself resolves. An authored ask is a DISPATCHED node with a
  # resolution token minted by the kernel — the run cannot complete past it, and it
  # announces no attention (the token-holding kind never does), so a run
  # waiting on its verdict reads as `running` and its steers keep today's
  # meaning. Without it a settled check with nothing else started would
  # COMPLETE the run before the gate could plant the next attempt. The
  # daemon resolves it INSIDE the append that plants the next attempt:
  # one atomic envelope, key-addressed (`apply_resolves` supplies the
  # node's own token in the authoring trust domain), so nothing secret
  # has to be kept anywhere. `absorb` on the check means a could-not-run
  # or an expired park still satisfies the hold's dependency, so the hold
  # parks in every arm and the gate reads the row. If the daemon dies
  # mid-attempt, the hold times out and the run surfaces that the
  # ordinary way, instead of standing open forever.
  #
  # LEVEL-TRIGGERED FROM THE TRACE. The follower's events are a nudge;
  # one `fetch` of the trace is the predicate: the current hold is parked,
  # its check has settled, no round or tool call is live, the run is
  # asking nobody. An expansion narrated in two envelopes, a feed replayed
  # after re-adoption, a stale follower table — all collapse into "not
  # yet", and a `checking` latch makes two nudges one read. The attempt
  # number is read off the trace's own keys.
  #
  # `rho stop` cancels a running check the way it cancels any tool call —
  # the kernel's stop reaches the runner's cancel path; the gate kills
  # nothing itself.
  module Until
    CHECK_KEY = "check".freeze
    HOLD_KEY = "hold".freeze
    WORK_KEY = "work".freeze
    SUMMARY_KEY = "summary".freeze
    REPORT_KEY = "report".freeze
    DEFAULT_ATTEMPTS = 5
    MAX_ATTEMPTS = 20
    # The hold parks from its check's settle until the mainline ends, so it
    # must outlast the whole task. Twelve hours, under the kernel's
    # 24-hour per-park clamp.
    HOLD_TIMEOUT_MS = 12 * 60 * 60 * 1000
    # THE CHECK'S OWN PARK, explicit on the step: bash's ceiling plus a
    # minute of claim latency, so the park never follows an announced
    # profile a runner might change.
    CHECK_PARK_MS = 10 * 60 * 1000
    WORK_KINDS = %w[model_task tool_task delegation_task].freeze
    # A refused append is retried this many times before the gate gives
    # the run back: the verdict is on the row, so only the recording is
    # retried, never the command.
    APPEND_RETRIES = 3
    APPEND_BACKOFF_SECONDS = 2.0
    # Bash's own sentence on a timeout (`Tools::Bash#finalize`), the one
    # sentinel a `completed` row without an exit status carries.
    TIMEOUT_SENTENCE = "Command timed out".freeze

    # `runner` is the bound runner's public id when the check runs
    # elsewhere; nil for this machine's own or none. `directory` is nil
    # when nothing knows where the tree is (bash then runs in the
    # runner's root). Both are kept as nils so the store round-trips.
    Policy = Data.define(:command, :attempts, :directory, :runner, :seed) do
      def self.from_h(hash)
        new(command: hash.fetch("command"), attempts: Integer(hash.fetch("attempts")),
            directory: hash["directory"], runner: hash["runner"], seed: hash.fetch("seed"))
      end

      def to_h
        { "command" => command, "attempts" => attempts, "directory" => directory, "runner" => runner, "seed" => seed }
      end
    end

    Check = Data.define(:attempt, :attempts, :exit_status, :timed_out, :passed, :at) do
      def to_h = super.transform_keys(&:to_s)

      def verdict
        return "passed" if passed
        return "timed out" if timed_out
        exit_status.nil? ? "killed" : "exit #{exit_status}"
      end
    end

    # WHAT A SETTLED ROW SAYS. `reason` set means the check could not be
    # run at all — the run is given back with it; otherwise the exit
    # status (or the timeout) is the verdict.
    Verdict = Data.define(:status, :exit_status, :timed_out, :reason) do
      def passed? = status == "completed" && exit_status == 0
      def runnable? = reason.nil?
    end

    module_function

    # THE ONE FOLD of the two flags into the body: the
    # `until` block the daemon's `:turn_author` reads, or the body as it
    # came when no command was typed. The shipped `run` folds through it
    # (`Extensions::Until.register` puts the flags on the verb) and so
    # does rho-dev's `do` — one spelling, no cross-extension reference.
    # `until` is a reserved word, so the keyword is read off the binding.
    def fold(body, until:, attempts: nil)
      command = binding.local_variable_get(:until)
      return body if command.nil?

      body.merge("until" => { "command" => command, "attempts" => attempts || DEFAULT_ATTEMPTS })
    end

    # THE PARAGRAPH, in the instructions channel: byte-stable for the
    # run's life, and present only when --until was given, so a run
    # without one carries today's instructions to the byte.
    def paragraph(command:, attempts:, directory:)
      "The acceptance check is `#{command}`, run in #{directory || "the runner's root"}. Run it yourself before " \
        "you finish. When you believe the task is done, end your turn with a short message " \
        "saying what you did; the check will then be run for you. If it fails you will see " \
        "its output and be asked to continue; you have #{attempts} checks in total. Make it " \
        "pass by completing the task — do not edit, skip or weaken what the command checks."
    end

    def check_key(attempt) = "#{CHECK_KEY}-#{attempt}"

    def hold_key(attempt) = "#{HOLD_KEY}-#{attempt}"

    # DETERMINISTIC AND 36 BYTES: the receipt's column is UUID-sized, so a
    # readable key would not fit; a digest shaped like one does, and the
    # same (run, attempt, step) always spells the same key.
    def idempotency_key(public_id, attempt, step = "check")
      hex = Digest::SHA256.hexdigest("until:#{public_id}:#{attempt}:#{step}")
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end
    # THE FIRST ROUND IS THE KERNEL'S: a turn's seed round
    # is minted `r1` by ApplyNext, and the check hangs below it; every later
    # attempt is a round this gate plants under its own name.
    FIRST_ROUND_KEY = "r1".freeze

    def work_key(attempt) = attempt == 1 ? FIRST_ROUND_KEY : "#{WORK_KEY}-#{attempt}"

    # Either prefix: the check and its hold carry one attempt number.
    def attempt_of(key)
      key.delete_prefix("#{CHECK_KEY}-").delete_prefix("#{HOLD_KEY}-").to_i
    end

    # ONE ENVELOPE, placed by position: the check waits on its attempt's
    # round and resolves the host's default Runner when accepted; the hold waits on the check and
    # is the deliverable that keeps the run open. `workdir` is omitted
    # when the directory is unknown (bash runs in the runner's root).
    def check_steps(attempt, command:, directory:, timeout_seconds:)
      [
        CybrosAgent::Steps::Tool.new(
          name: "bash", key: check_key(attempt), route: { "kind" => "runner" },
          input: { "command" => command, "workdir" => directory, "timeout" => timeout_seconds }.compact,
          timeout_ms: CHECK_PARK_MS, on_failure: "absorb"
        ),
        CybrosAgent::Steps::Ask.new(
          key: hold_key(attempt), prompt: "verdict of acceptance check #{attempt}", timeout_ms: HOLD_TIMEOUT_MS
        ),
      ]
    end

    # THE ONE READER OF A SETTLED ROW, through the bash tool's own
    # contract: `exit_status` rides the structured content on every exit;
    # a timeout is `completed` with none and bash's sentence in the
    # output; `completed` with neither is bash refusing to start (its
    # first line says why); anything else is the runner not running it —
    # `tool_not_served`, an expired park, a claim that died — and the
    # row's error says which.
    def verdict_of(detail)
      task = detail.task
      output = detail.output.to_s
      return Verdict.new(status: task.status, exit_status: nil, timed_out: false,
        reason: task.error&.dig("detail") || task.error&.dig("key") || task.status) unless task.status == "completed"

      exit_status = detail.structured_content&.dig("exit_status")
      return Verdict.new(status: "completed", exit_status: exit_status, timed_out: false, reason: nil) if exit_status
      return Verdict.new(status: "completed", exit_status: nil, timed_out: true, reason: nil) if output.include?(TIMEOUT_SENTENCE)

      first = output.lines.first.to_s.strip
      Verdict.new(status: "completed", exit_status: nil, timed_out: false,
        reason: first.empty? ? "the check answered nothing" : first)
    end

    class Gate
      # BOUND TO ONE RUN: the follower nudges this gate
      # only while that run backs the turn it follows, and `reconsider`
      # is handed that run's own context — the trace it reads, the row it
      # reads and the door it appends through are the run's, never the
      # conversation's.
      attr_reader :run_public_id

      def initialize(policy:, timeout_seconds:, run_public_id: nil, log: nil, clock: -> { Time.now },
                     sleeper: ->(seconds) { sleep(seconds) })
        @run_public_id = run_public_id
        @policy = policy
        @timeout_seconds = timeout_seconds
        @log = log
        @clock = clock
        @sleeper = sleeper
        @mutex = Mutex.new
        @checking = false
        @done = false
        @checks = []
      end

      def checks = @mutex.synchronize { @checks.dup }
      def done? = @mutex.synchronize { @done }

      def to_h
        { "command" => @policy.command, "attempts" => @policy.attempts,
          "directory" => @policy.directory, "runner" => @policy.runner, "run_public_id" => @run_public_id,
          "checks" => checks.map(&:to_h) }.compact
      end

      # THE FOLLOWER'S TABLE IS A FILTER, never the verdict: a nudge is
      # worth a trace fetch only when the table shows a hold parked, its
      # check settled and nothing else live. Cheap, and wrong in the safe
      # direction — a stale table sends one extra fetch or waits for the
      # next event.
      def worth_a_look?(tasks)
        return false if done?

        # `started?`, not a list of words: the hold's own status is
        # `dispatched` (its resolution_token rode out in the append
        # receipt), and asking whether it has BEGUN is the question either
        # way. A hand-written live list here is what went blind before.
        hold = tasks.find { |t| t.kind == "await_task" && t.started? && t.task_key.start_with?("#{HOLD_KEY}-") }
        return false if hold.nil?

        check = Until.check_key(Until.attempt_of(hold.task_key))
        tasks.any? { |t| t.task_key == check && t.terminal? } &&
          tasks.none? { |t| WORK_KINDS.include?(t.kind) && t.live? }
      end

      # ONE FETCH, ONE READ, ONE VERDICT. Runs on a reactor fiber.
      def reconsider(context)
        return unless @mutex.synchronize { @checking || @done ? false : (@checking = true) }

        begin
          run = context.fetch
          attempt = ready?(run)
          return if attempt.nil?

          verdict = Until.verdict_of(context.task(Until.check_key(attempt)))
          if verdict.runnable?
            record(attempt, verdict)
            recording(context, run, attempt) { append(context, run, attempt, verdict) }
          else
            # A predicate the runner could not START — no bash there, the
            # directory gone, the park expired — is the operator's problem:
            # give the run back with the reason, so it closes and `rho
            # result` says why.
            @log&.warn("until.check_unrunnable", command: @policy.command, task: Until.check_key(attempt),
              status: verdict.status, detail: verdict.reason)
            release(context, "the acceptance check could not be run: #{verdict.reason}",
              run: run, attempt: attempt)
          end
        ensure
          @mutex.synchronize { @checking = false }
        end
      end

      # THE VERDICT IS ON THE ROW; ONLY THE RECORDING IS RETRIED. A moved
      # trace (a steer landed) is left for the next nudge; anything else
      # is retried briefly and then the run is given back — a run that
      # stood behind its hold for twelve hours because one append failed
      # would be the wedge this design exists to avoid.
      def recording(context, run, attempt)
        tries = 0
        begin
          yield
        rescue CybrosAgent::Api::Conflict => error
          @log&.warn("until.append_conflict", command: @policy.command, detail: error.message)
        rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
          tries += 1
          if tries <= APPEND_RETRIES
            @log&.warn("until.append_retry", attempt: attempt, try: tries, error_class: error.class.name,
              detail: CybrosAgent::Redaction.call(error.message))
            @sleeper.call(APPEND_BACKOFF_SECONDS * tries)
            retry
          end
          @log&.warn("until.abandoned", command: @policy.command, error_class: error.class.name,
            detail: CybrosAgent::Redaction.call(error.message))
          release(context, "the acceptance check's verdict could not be recorded " \
                           "(#{error.class.name.split("::").last}: #{CybrosAgent::Redaction.call(error.message)})",
            run: run, attempt: attempt)
        end
      end

      # GIVE THE RUN BACK: resolve the hold and plant the report round
      # with the reason, so the run completes and the person reads why.
      # Best effort — if this append fails too, the hold's own timeout
      # is the last resort, and the log says so.
      def release(context, reason, run: nil, attempt: nil)
        @mutex.synchronize { @done = true }
        run ||= context.fetch
        attempt ||= ready?(run)
        return if attempt.nil?

        context.append(
          steps: [round(REPORT_KEY, release_prompt(reason), attempt)],
          resolve: [{ "task" => Until.hold_key(attempt), "content" => "check #{attempt}/#{@policy.attempts}: #{reason}" }],
          idempotency_key: Until.idempotency_key(run.public_id, attempt, "release")
        )
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
        @log&.warn("until.release_failed", error_class: error.class.name,
          detail: CybrosAgent::Redaction.call(error.message))
      end

      # Ends the policy. A check in flight is a claimed row on the runner,
      # cancelled by the kernel's stop like any tool call — not from here.
      def cancel!
        @mutex.synchronize { @done = true }
      end

      # THE PREDICATE, OVER THE TRACE: the run is running and asking
      # nobody; the current hold is parked and its check has settled (a
      # settled check implies its round settled, by position); no round or
      # tool call or child report is pending; and nothing has been planted past this attempt
      # already. Answers the attempt.
      def ready?(run)
        return nil unless run.status == "running" && run.attention.nil?

        tasks = run.tasks
        current = tasks.select { |t| t.await? && t.key.start_with?("#{HOLD_KEY}-") }
                       .max_by { |t| Until.attempt_of(t.key) }
        return nil unless current&.started?

        attempt = Until.attempt_of(current.key)
        check = tasks.find { |t| t.key == Until.check_key(attempt) }
        return nil unless check&.terminal?
        return nil if tasks.any? { |t| WORK_KINDS.include?(t.kind) && t.live? }

        planted = [SUMMARY_KEY, REPORT_KEY, Until.work_key(attempt + 1)]
        return nil if tasks.any? { |t| planted.include?(t.key) }

        attempt
      end

      private

        def record(attempt, verdict)
          check = Check.new(
            attempt: attempt, attempts: @policy.attempts, exit_status: verdict.exit_status,
            timed_out: verdict.timed_out, passed: verdict.passed?, at: @clock.call.iso8601
          )
          @mutex.synchronize { @checks << check }
          @log&.info("until.checked", attempt: attempt, attempts: @policy.attempts, verdict: check.verdict,
            runner: @policy.runner || "own", task: Until.check_key(attempt))
        end

        # ONE ENVELOPE: the verdict resolves the hold, and the next steps
        # are placed after it — the envelope's end is the run's answer.
        def append(context, run, attempt, verdict)
          context.append(
            steps: next_steps(attempt, verdict),
            resolve: [{ "task" => Until.hold_key(attempt), "content" => verdict_line(attempt, verdict) }],
            idempotency_key: Until.idempotency_key(run.public_id, attempt)
          )
          @mutex.synchronize { @done = true } if verdict.passed? || attempt >= @policy.attempts
        end

        def next_steps(attempt, verdict)
          if verdict.passed?
            [round(SUMMARY_KEY, summary_prompt, attempt)]
          elsif attempt >= @policy.attempts
            [round(REPORT_KEY, report_prompt(attempt, verdict), attempt)]
          else
            [round(Until.work_key(attempt + 1), continue_prompt(attempt, verdict), attempt),
             *Until.check_steps(attempt + 1, command: @policy.command, directory: @policy.directory,
               timeout_seconds: @timeout_seconds)]
          end
        end

        # The seed is the surface every attempt copies (model, tools, the
        # kernel's compaction). The round continues the run's own mainline and
        # reads nothing else by position, so it names the rows of the earlier
        # append it reads: the attempt's check (the output) and its hold (the
        # verdict line this same append resolves).
        def round(key, prompt, attempt)
          CybrosAgent::Steps::Model.new(key: key, prompt: prompt,
            results: [Until.check_key(attempt), Until.hold_key(attempt)], **@policy.seed.transform_keys(&:to_sym))
        end

        def verdict_line(attempt, verdict)
          how = verdict.passed? ? "passed" : (verdict.timed_out ? "timed out" : "exit #{verdict.exit_status.inspect}")
          "check #{attempt}/#{@policy.attempts}: #{how}"
        end

        def release_prompt(reason)
          "The acceptance check `#{@policy.command}` cannot continue: #{reason}. Do not continue " \
            "working. Reply with a short report of what you did and what remains."
        end

        def summary_prompt
          "The acceptance check `#{@policy.command}` passed. Reply with a short summary of what " \
            "you did; that is this run's answer."
        end

        def continue_prompt(attempt, verdict)
          "#{failure_header(attempt, verdict)}\n\n" \
            "Continue the task so the check passes — do not edit, skip or weaken what it " \
            "checks. When you believe it is done, end your turn with a short message."
        end

        def report_prompt(attempt, verdict)
          "#{failure_header(attempt, verdict)} That was the last allowed run.\n\n" \
            "Do not continue working. Reply with a short " \
            "report: what you did, what still fails, and what you would try next."
        end

        # The output is the check row's result, which the round names in its
        # `results:` and reads as the envelope ahead of this prompt — one
        # copy, never two.
        def failure_header(attempt, verdict)
          how = verdict.timed_out ? "did not finish in time" : "exited with status #{verdict.exit_status.inspect}"
          "The acceptance check `#{@policy.command}` #{how} (check #{attempt} of #{@policy.attempts}). " \
            "Its output is the result of `#{Until.check_key(attempt)}` above."
        end
    end
  end
end
