require "io/wait"
require "securerandom"

module Rho
  class Runner
    module Tools
      # Ported from pi's bash.ts + output-accumulator.ts + child-process.ts:
      # /bin/bash -c execution in its own process group, stdout and stderr
      # merged into one pipe in arrival order, a bounded rolling tail with a
      # full raw spill file once the output no longer fits, a wall-clock
      # timeout that SIGKILLs the whole group, and the post-exit drain grace
      # of pi#5303 (a detached grandchild holding the pipe must neither stall
      # the result forever nor have its in-flight output cut mid-write).
      # Deviations from pi:
      # - A wall-clock timeout defaults to env.bash_timeout_seconds.
      # - The child inherits the runner's PATH, without pi's bin prepend.
      # - Totals count raw bytes; newline bytes cannot occur inside a UTF-8 sequence.
      # Progress callbacks report the running tail through the executor channel.
      class Bash
        NAME = "bash"
        # The ceiling a caller may ask for, carried from the predecessor.
        # It is a bound on ONE command, not on the task: the park's own
        # deadline is the real clock and it belongs to the server.
        MAX_TIMEOUT_SECONDS = 540
        # bash CLAMPS ITSELF — the wall-clock timeout above kills the
        # group — so the runner never asks the kernel for more time on
        # its behalf (executor.md "Extend"): a command that runs long is
        # a command that timed out, never a park to stretch.
        INTERNAL_CLAMP = true
        # Arbitrary commands: effectful and open-world.
        EFFECT_PROFILE = {
          "kind" => "write", "destructive" => true, "world" => "open",
          "idempotency" => "none", "reconciliation" => "none",
        }.freeze

        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "command" => { "type" => "string", "description" => "Bash command to execute" },
            # THE PARAMETER BASH WAS THE ONLY TOOL WITHOUT. The other six
            # take a path; this one silently ran everything in the
            # runner's root, so placing a command meant `cd X && ...` in
            # every single call — and forgetting it ran the command
            # somewhere the caller never named.
            "workdir" => {
              "type" => "string",
              "description" => "Directory to run the command in (absolute, or relative to the " \
                               "runner root). Defaults to the runner root. Use this rather than `cd`.",
            },
            "timeout" => {
              "type" => "number",
              "exclusiveMinimum" => 0,
              "maximum" => MAX_TIMEOUT_SECONDS,
              "description" => "Timeout in seconds (optional; defaults to the runner's bash timeout)",
            },
          },
          "required" => ["command"],
        })

        # THE SENTENCE ABOUT `&`. This call kills its whole process group
        # when it returns, so a server backgrounded with `&` or nohup is
        # dead before the model reads "started". Saying so here — and
        # naming the tool that keeps a process alive — is the difference
        # between a model that starts a dev server once and one that
        # restarts it every round and never understands why it is gone.
        BACKGROUND_NOTE =
          "Use for commands that finish. Anything left running with `&` or nohup is killed " \
          "when this call returns; for a server or a watcher, use start_process.".freeze

        DESCRIPTION =
          "Execute a bash command. Runs in the runner root unless `workdir` names another " \
          "directory. Returns stdout and stderr. " \
          "Output is truncated to last #{Truncation::DEFAULT_MAX_LINES} lines or " \
          "#{Truncation::DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first). If truncated, " \
          "full output is saved to a temp file. Optionally provide a timeout in seconds. " \
          "#{BACKGROUND_NOTE}".freeze

        PROMPT_SNIPPET = "Execute bash commands (ls, grep, find, etc.)".freeze
        PROMPT_GUIDELINES = [
          "Pass workdir to bash rather than `cd <dir> && ...`.",
          "A server or anything that must outlive the call: start_process, never `&`.",
        ].freeze

        SHELL = "/bin/bash"
        POLL_INTERVAL_SECONDS = 0.05
        DRAIN_GRACE_SECONDS = 0.1
        READ_CHUNK_BYTES = 64 * 1024
        READ_BURST_CHUNKS = 64
        # The tail a progress frame carries: enough lines to read where a
        # build is, a fraction of the kernel's 64 KiB frame bound.
        PROGRESS_TAIL_BYTES = 4 * 1024

        def initialize(env:)
          @env = env
        end

        def call(args)
          @env.raise_if_cancelled!
          command = args.fetch("command")
          timeout_seconds = args.key?("timeout") ? args["timeout"] : @env.bash_timeout_seconds
          unless valid_timeout?(timeout_seconds)
            return Result.error(
              "Invalid timeout: must be a finite positive number no greater than " \
              "#{MAX_TIMEOUT_SECONDS} seconds"
            )
          end
          workdir = @env.resolve(args["workdir"].to_s.empty? ? "." : args["workdir"].to_s)
          unless File.directory?(workdir)
            return Result.error("Working directory does not exist: #{workdir}\nCannot execute bash commands.")
          end

          run(command, timeout_seconds, workdir)
        end

        private

        def valid_timeout?(value)
          value.is_a?(Numeric) && value.finite? && value.positive? &&
            value <= MAX_TIMEOUT_SECONDS
        end

        def run(command, timeout_seconds, workdir)
          accumulator = Accumulator.new(env: @env)
          reader, writer = IO.pipe
          reader.binmode
          child = nil
          outcome = nil

          begin
            child = spawn_shell(command, writer, workdir)
          rescue SystemCallError, ArgumentError => e
            return Result.error("Failed to start bash: #{e.message}")
          ensure
            writer.close
          end

          outcome = ExecutionContext.with_cancel_signal(-> { child.cancel }) do
            deadline = monotonic + timeout_seconds
            status = supervise(child, reader, accumulator, deadline)
            @env.raise_if_cancelled!
            settled =
              if status == :timeout
                read_available(reader, accumulator)
                finalize(accumulator, status: nil, timeout_seconds:, timed_out: true)
              elsif drain_after_exit(reader, accumulator, deadline) == :deadline
                # The shell exited but an orphaned descendant kept the pipe busy
                # past the wall clock (pi keeps its timeout timer armed across
                # the whole drain and fires killProcessTree): kill the group so
                # the orphan dies too, and report the timeout honestly.
                child.cancel
                finalize(accumulator, status: nil, timeout_seconds:, timed_out: true)
              else
                finalize(accumulator, status:, timeout_seconds:, timed_out: false)
              end
            # The shell may exit successfully after launching quiet background
            # children that still belong to this call's process group. Result
            # delivery transfers no ownership for them, so terminate the whole
            # group before reaping its process-group identity guard.
            child.kill_and_reap
            settled
          end
          outcome
        ensure
          # A non-local exit (turn/interrupt Async-stopping the executor fiber) lands here with no
          # outcome: SIGKILL the spawned process group and reap the shell so an interrupt never
          # orphans children. Normal paths always settled or reaped the group first.
          child&.kill_and_reap if outcome.nil?
          reader&.close
          accumulator&.finish
        end

        # Own process group so a timeout can kill the whole tree; stdin from
        # /dev/null; stdout and stderr share ONE pipe so the model sees the
        # interleaved output in arrival order. The environment is the
        # child's own (ChildEnv), not this process's Bundler-shaped one.
        def spawn_shell(command, writer, workdir)
          OwnedProcess.spawn(
            ChildEnv.call, SHELL, "-c", command,
            chdir: workdir, in: File::NULL, out: writer, err: writer,
            unsetenv_others: true
          )
        end

        # Pump the pipe and poll for exit under one wall-clock deadline. EOF
        # flips the wait to plain sleeping so a closed pipe cannot busy-spin
        # while the child is still running. WHAT THE COMMAND HAS SAID SO FAR
        # is handed to the watcher's channel as it grows (executor.md
        # "Progress"): the rolling tail's last `PROGRESS_TAIL_BYTES`, only
        # when new bytes arrived — the context posts it at the kernel's
        # cadence, on the reactor, never from here.
        def supervise(child, reader, accumulator, deadline)
          eof = false
          seen = 0
          loop do
            @env.raise_if_cancelled!
            eof = true if read_available(reader, accumulator) == :eof
            if accumulator.total_bytes > seen
              seen = accumulator.total_bytes
              @env.report_progress(accumulator.tail_text(PROGRESS_TAIL_BYTES))
            end
            status = child.poll
            return status if status

            remaining = deadline - monotonic
            if remaining <= 0
              child.kill_and_reap
              return :timeout
            end

            interval = [remaining, POLL_INTERVAL_SECONDS].min
            eof ? sleep(interval) : reader.wait_readable(interval)
          end
        end

        # Drains whatever is already buffered without ever blocking: :wait
        # when the pipe is open but idle, :eof once every writer is gone,
        # :more when the per-call chunk budget ran out while data kept
        # coming — callers loop with their own deadline checks, so a
        # flooding writer can never starve those checks.
        def read_available(reader, accumulator)
          READ_BURST_CHUNKS.times do
            @env.raise_if_cancelled!
            chunk = reader.read_nonblock(READ_CHUNK_BYTES, exception: false)
            return :wait if chunk == :wait_readable
            return :eof if chunk.nil?

            accumulator.append(chunk)
          end
          :more
        end

        # The pi#5303 drain grace: after the child exits, a detached
        # grandchild may still hold the write end. The 100ms idle timer is
        # RE-ARMED on every chunk — an actively writing descendant keeps us
        # reading, a quiet inherited handle releases us once the grace
        # elapses, and EOF ends the drain immediately. The overall wall-clock
        # deadline still applies (an orphan writing with sub-grace gaps must
        # not stall the result forever): returns :deadline when it expires.
        def drain_after_exit(reader, accumulator, deadline)
          loop do
            @env.raise_if_cancelled!
            return :ok if read_available(reader, accumulator) == :eof

            remaining = deadline - monotonic
            return :deadline if remaining <= 0

            if remaining < DRAIN_GRACE_SECONDS
              # Not enough runway for a full grace window: whichever timer
              # fires first wins in pi, and here that is the wall clock.
              return :deadline unless reader.wait_readable(remaining)
            else
              return :ok unless reader.wait_readable(DRAIN_GRACE_SECONDS)
            end
          end
        end

        def finalize(accumulator, status:, timeout_seconds:, timed_out:)
          accumulator.finish
          snapshot = accumulator.snapshot
          details = structured_details(snapshot)
          footer = render_footer(snapshot)

          # THE SPILL IS A CAPTURE: the footer names its path for
          # the model (`read` on this runner); the run uploads and links the
          # same file for a client beside it, never instead of it.
          files = snapshot.spill_path ? [snapshot.spill_path] : []
          if timed_out
            message = "Command timed out after #{format_seconds(timeout_seconds)} seconds"
            return Result.error(append_status("#{snapshot.content}#{footer}", message), details, files: files)
          end

          base = snapshot.content.empty? ? "(no output)" : snapshot.content
          text = "#{base}#{footer}"
          exit_code = status.exitstatus
          details = with_exit_status(details, exit_code)
          # exitstatus nil means killed by a signal that was NOT our timeout:
          # pi returns the output normally in that case (null exit code).
          return Result.ok(text, details, files: files) if exit_code.nil? || exit_code.zero?

          Result.error(append_status(text, "Command exited with code #{exit_code}"), details, files: files)
        end

        def append_status(text, status_line)
          text.empty? ? status_line : "#{text}\n\n#{status_line}"
        end

        # pi's formatOutput footers, verbatim shapes.
        def render_footer(snapshot)
          truncation = snapshot.truncation
          return nil unless truncation.truncated

          first = truncation.total_lines - truncation.output_lines + 1
          last = truncation.total_lines
          if truncation.last_line_partial
            kept = Truncation.format_size(truncation.output_bytes)
            full = Truncation.format_size(snapshot.last_line_bytes)
            "\n\n[Showing last #{kept} of line #{last} (line is #{full}). Full output: #{snapshot.spill_path}]"
          elsif truncation.truncated_by == :lines
            "\n\n[Showing lines #{first}-#{last} of #{truncation.total_lines}. Full output: #{snapshot.spill_path}]"
          else
            "\n\n[Showing lines #{first}-#{last} of #{truncation.total_lines} " \
            "(#{Truncation.format_size(truncation.max_bytes)} limit). Full output: #{snapshot.spill_path}]"
          end
        end

        def structured_details(snapshot)
          details = {}
          details["truncation"] = snapshot.truncation.to_h.transform_keys(&:to_s) if snapshot.truncation.truncated
          details["spill_path"] = snapshot.spill_path if snapshot.spill_path
          details.empty? ? nil : details
        end

        def with_exit_status(details, exit_code)
          return details if exit_code.nil?

          (details || {}).merge("exit_status" => exit_code)
        end

        def format_seconds(value)
          whole = value.to_i
          value == whole ? whole.to_s : value.to_s
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        Snapshot = Data.define(:content, :truncation, :spill_path, :last_line_bytes)

        # Port of pi's OutputAccumulator: bounded-memory rolling tail for the
        # model-facing snapshot, plus a complete raw spill file once totals
        # cross the display limits. Raw chunks are buffered until the spill
        # decision so the file is complete from byte 0; every chunk after the
        # decision is appended directly.
        class Accumulator
          MAX_LINES = Truncation::DEFAULT_MAX_LINES
          MAX_BYTES = Truncation::DEFAULT_MAX_BYTES
          MAX_ROLLING_BYTES = MAX_BYTES * 2
          SPILL_PREFIX = "bash".freeze

          attr_reader :total_bytes

          def initialize(env:)
            @env = env
            @tail = String.new(encoding: Encoding::BINARY)
            @tail_at_line_boundary = true
            @buffered = []
            @total_bytes = 0
            @completed_lines = 0
            @current_line_bytes = 0
            @open_line = false
            @spill_path = nil
            @spill_io = nil
            @finished = false
          end

          # THE LAST BYTES, for a watcher: the decoded rolling tail cut to
          # `max_bytes` at a character boundary and then to the first whole
          # line, so a frame never opens mid-line or mid-character.
          def tail_text(max_bytes)
            text = decoded_tail
            return text if text.bytesize <= max_bytes

            cut = text.byteslice(text.bytesize - max_bytes, max_bytes).scrub("")
            index = cut.index("\n")
            index.nil? ? cut : cut[(index + 1)..]
          end

          def append(chunk)
            raise "cannot append to a finished accumulator" if @finished

            @total_bytes += chunk.bytesize
            count_lines(chunk)
            append_tail(chunk)

            if @spill_io || spill_needed?
              ensure_spill!
              @spill_io.write(chunk)
            else
              @buffered << chunk
            end
          end

          # The spill closes, then takes its content's name: the footer and
          # the capture beside it name the same bytes the same way every run.
          def finish
            return if @finished

            @finished = true
            ensure_spill! if spill_needed?
            @spill_io&.close
            @spill_io = nil
            @spill_path = @env.keep_capture(@spill_path, SPILL_PREFIX) if @spill_path
          end

          # The window truncation runs over the decoded rolling tail; the
          # truncated flag and totals come from the whole-stream counters
          # (pi OutputAccumulator#snapshot).
          def snapshot
            window = Truncation.truncate_tail(decoded_tail)
            truncated = total_lines > MAX_LINES || @total_bytes > MAX_BYTES
            truncated_by = truncated ? (window.truncated_by || overflow_axis) : nil
            truncation = window.with(truncated:, truncated_by:, total_lines:, total_bytes: @total_bytes)
            Snapshot.new(content: truncation.content, truncation:, spill_path: @spill_path,
                         last_line_bytes: @current_line_bytes)
          end

          private

          def total_lines
            @completed_lines + (@open_line ? 1 : 0)
          end

          def overflow_axis
            @total_bytes > MAX_BYTES ? :bytes : :lines
          end

          def spill_needed?
            @total_bytes > MAX_BYTES || total_lines > MAX_LINES
          end

          def count_lines(chunk)
            newlines = chunk.count("\n")
            if newlines.zero?
              @current_line_bytes += chunk.bytesize
              @open_line = true
            else
              @completed_lines += newlines
              open_tail = chunk.byteslice((chunk.rindex("\n") + 1)..)
              @current_line_bytes = open_tail.bytesize
              @open_line = !open_tail.empty?
            end
          end

          # Rolling tail: trim from the front at a valid UTF-8 boundary once
          # the buffer passes 2x the rolling cap, remembering whether the new
          # head still starts at a line boundary (pi trimTail).
          def append_tail(chunk)
            @tail << chunk
            return if @tail.bytesize <= MAX_ROLLING_BYTES * 2

            start = @tail.bytesize - MAX_ROLLING_BYTES
            start += 1 while start < @tail.bytesize && (@tail.getbyte(start) & 0xC0) == 0x80
            @tail_at_line_boundary = start.zero? ? @tail_at_line_boundary : @tail.getbyte(start - 1) == 0x0A
            @tail = @tail.byteslice(start..)
          end

          # Snapshots must not start mid-line: when the trim landed inside a
          # line, drop through the first newline (pi getSnapshotText). Invalid
          # UTF-8 is scrubbed, never fatal.
          def decoded_tail
            text =
              if @tail_at_line_boundary
                @tail
              else
                index = @tail.index("\n")
                index.nil? ? @tail : @tail.byteslice((index + 1)..)
              end
            text.dup.force_encoding(Encoding::UTF_8).scrub
          end

          # A random name while the run streams into it; `finish` renames it
          # to its content's.
          def ensure_spill!
            return if @spill_path

            @spill_path = File.join(@env.ensure_artifacts_dir!, "#{SPILL_PREFIX}-#{SecureRandom.hex(8)}.log")
            @spill_io = File.open(@spill_path, "wb")
            @buffered.each { |chunk| @spill_io.write(chunk) }
            @buffered = []
          end
        end

        private_constant :Snapshot, :Accumulator
      end
    end
  end
end
