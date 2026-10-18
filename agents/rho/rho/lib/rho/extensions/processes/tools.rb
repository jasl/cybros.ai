module Rho
  module Extensions
    module Processes
      # Bytes matter (the tool list heads every cached prefix), so each
      # description is one paragraph with one example of the answer: a name
      # plus one example moved valid-first calls from two in ten to seven.
      module Tools
        Result = Rho::Runner::Result

        NO_HOST = "start_process is not available here: this runner has no daemon to own a process".freeze
        READ_PROFILE = {
          "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        }.freeze
        WRITE_PROFILE = {
          "kind" => "write", "destructive" => true, "effect_scope" => "open",
          "idempotency" => "none", "reconciliation" => "none",
        }.freeze

        module Shared
          def caller_id = Rho::Runner::ExecutionContext.current&.run_public_id
          # The registry gates by the caller's conversation — the kernel's
          # word on the inbox row, carried by the context (nil: a standalone
          # run, which owns by its own id); a call outside a task (a test,
          # a probe) is the person's.
          def caller = caller_id || "user"
          def caller_conversation = Rho::Runner::ExecutionContext.current&.conversation_public_id
          def caller_source
            context = Rho::Runner::ExecutionContext.current
            return nil if context.nil? || context.claim_token.nil?

            { "run_public_id" => context.run_public_id, "task_key" => context.task_key,
              "claim_token" => context.claim_token }.freeze
          end
          def unavailable = Result.error(NO_HOST)

          # The owner is the conversation; the run that called is shown beside it when it is not
          # the owner itself.
          def render_row(row)
            line = "#{row.id}  #{row.status}"
            line << " (#{row.exit_phrase})" if row.status == "exited"
            line << "  pid #{row.pid}  owner #{row.owner || "-"}"
            line << "  run #{row.run_public_id}" if row.run_public_id && row.run_public_id != row.owner
            line << "  "
            line << (row.name || row.command.byteslice(0, 60).scrub(""))
            line << "  (#{row.workdir})"
            line << "\n    #{row.ready_line}" if row.ready_line
            line
          end
        end

        class StartProcess
          include Shared

          NAME = "start_process"
          EFFECT_PROFILE = WRITE_PROFILE
          DEFAULT_WAIT_SECONDS = 10
          MAX_WAIT_SECONDS = 60
          TAIL_LINES = 30
          POLL_SECONDS = 0.1
          EOF_POLL_SECONDS = 0.01

          SCHEMA = Ractor.make_shareable({
            "type" => "object",
            "properties" => {
              "command" => {
                "type" => "string",
                "description" => "Shell command to run and keep running, in the foreground — never -d, " \
                                 "--daemon, nohup or a trailing &. A command that exits during the wait is " \
                                 "reported as exited, and whatever it left behind is neither tracked nor stoppable.",
              },
              "workdir" => {
                "type" => "string",
                "description" => "Directory to run the command in (absolute, or relative to the " \
                                 "runner root). Defaults to the runner root.",
              },
              "name" => { "type" => "string", "description" => "A short label for listings, e.g. \"web dev server\"." },
              "wait_for" => {
                "type" => "string",
                "description" => "Answer as soon as an output line contains this text (case-insensitive), " \
                                 "e.g. \"listening on\" or \"ready in\".",
              },
              "wait_seconds" => {
                "type" => "number", "minimum" => 0, "maximum" => MAX_WAIT_SECONDS,
                "description" => "How long to wait for wait_for or an exit before answering " \
                                 "(default #{DEFAULT_WAIT_SECONDS}, max #{MAX_WAIT_SECONDS}). " \
                                 "The process keeps running after the answer.",
              },
            },
            "required" => ["command"],
          })

          DESCRIPTION =
            "Start a long-running process — a dev server, a watcher — that keeps running after " \
            "this call returns, owned by this machine's daemon and visible to the person " \
            "(rho processes, rho kill). Answers with a header, then the output so far:\n" \
            "  p3 (pid 4242) running — web dev server\n" \
            "  ready: Local: http://localhost:3000\n" \
            "  log: ~/.rho/log/processes/p3.log\n" \
            "Use read_process for later output and stop_process when done. Empty output while " \
            "running is normal for a program that buffers stdout. No stdin and no TTY: an " \
            "interactive program will not work here.".freeze

          def initialize(env:)
            @env = env
          end

          def call(args)
            table = @env.processes
            return unavailable if table.nil?

            command = args["command"].to_s
            return Result.error("command is required") if command.strip.empty?

            workdir = @env.resolve(args["workdir"].to_s.empty? ? "." : args["workdir"].to_s)
            return Result.error("Working directory does not exist: #{workdir}") unless File.directory?(workdir)

            wait_for = blank_to_nil(args["wait_for"])
            wait_seconds = wait_budget(args["wait_seconds"])
            row = table.start(
              command:, workdir:, env: Rho::Runner::ChildEnv.call, name: blank_to_nil(args["name"])&.byteslice(0, 64),
              run_public_id: caller_id, conversation: caller_conversation, wait_for:, source: caller_source
            )
            wait(row, wait_seconds)
            answer(row, wait_for, wait_seconds)
          rescue Rho::Processes::Error => error
            Result.error(error.message)
          end

          private

            def blank_to_nil(value)
              text = value.to_s.strip
              text.empty? ? nil : text
            end

            def wait_budget(value)
              return DEFAULT_WAIT_SECONDS unless value.is_a?(Numeric) && value.finite?

              value.clamp(0, MAX_WAIT_SECONDS)
            end

            # A cancel mid-wait raises out; the row stays. That is the whole
            # point of daemon-lifetime ownership — the process outlives the
            # call that started it, including a cancelled one.
            #
            # THE LEADER EXITS A BEAT BEFORE ITS PIPE: the guard's poll can
            # answer the exit while the pump has not yet closed the output,
            # and a verdict read in that beat calls a plain exit "something
            # it started still holds its output". So once the leader is
            # gone, ONE bounded grace for the EOF — at most a poll slice,
            # never past the caller's deadline — before the answer is read.
            def wait(row, seconds)
              deadline = monotonic + seconds
              until row.leader_exited? || row.output.matched? || monotonic >= deadline
                @env.raise_if_cancelled!
                sleep POLL_SECONDS
              end
              await_eof(row, [monotonic + POLL_SECONDS, deadline].min) if row.leader_exited?
            end

            def await_eof(row, until_at)
              until row.output.eof? || monotonic >= until_at
                @env.raise_if_cancelled!
                sleep EOF_POLL_SECONDS
              end
            end

            def answer(row, wait_for, wait_seconds)
              snapshot = row.snapshot
              elapsed = (Time.now - row.started_at).round(1)
              header = ["#{snapshot.id} (pid #{snapshot.pid}) #{snapshot.status}#{" — #{snapshot.name}" if snapshot.name}"]
              header << verdict(row, snapshot, wait_for, wait_seconds, elapsed)
              header << "log: #{snapshot.log_path}"
              header << "workdir: #{snapshot.workdir}"
              body = row.output.lines(TAIL_LINES)
              body = "(no output yet — a program that buffers stdout prints nothing until it flushes)" if body.empty?
              text = "#{header.join("\n")}\n\n#{body}"
              failed = snapshot.status == "exited" && snapshot.exit_status != 0
              failed ? Result.error(text, snapshot.to_h) : Result.ok(text, snapshot.to_h)
            end

            def verdict(row, snapshot, wait_for, wait_seconds, elapsed)
              if snapshot.status == "exited"
                line = "exited with #{snapshot.exit_phrase} after #{elapsed}s"
                return line unless snapshot.exit_status&.zero?

                "#{line} — a process that exits during the wait is not a running one: run servers " \
                  "in the foreground (no -d, --daemon, nohup or &); nothing it left behind is tracked or stoppable"
              elsif snapshot.leader_exited
                "the command exited with #{snapshot.exit_phrase} but something it started still holds " \
                  "its output — the group is tracked as running, and stop_process ends all of it"
              elsif row.output.matched?
                "ready: #{snapshot.ready_line}"
              elsif wait_for
                "still starting after #{wait_seconds}s (no line contained #{wait_for.inspect} yet; read_process later)"
              else
                snapshot.ready_line ? "first line: #{snapshot.ready_line}" : "started (waited #{wait_seconds}s)"
              end
            end

            def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        class ListProcesses
          include Shared

          NAME = "list_processes"
          EFFECT_PROFILE = READ_PROFILE
          SCHEMA = Ractor.make_shareable({ "type" => "object", "properties" => {} })
          DESCRIPTION =
            "List the processes started with start_process on this machine — yours and other " \
            "runs' — with id, status, pid, owner and their readiness line. Check it before " \
            "starting a server that may already be running.".freeze

          def initialize(env:)
            @env = env
          end

          def call(_args)
            table = @env.processes
            return unavailable if table.nil?

            rows = table.snapshots
            text = rows.empty? ? "(no processes)" : rows.map { |row| render_row(row) }.join("\n")
            Result.ok(text, { "processes" => rows.map(&:to_h) })
          end
        end

        class ReadProcess
          include Shared

          NAME = "read_process"
          EFFECT_PROFILE = READ_PROFILE
          DEFAULT_LINES = 50
          MAX_LINES = 500
          SCHEMA = Ractor.make_shareable({
            "type" => "object",
            "properties" => {
              "id" => { "type" => "string", "description" => "The process id from start_process, e.g. p3." },
              "tail_lines" => {
                "type" => "integer", "minimum" => 1, "maximum" => MAX_LINES,
                "description" => "How many of the latest lines to return (default #{DEFAULT_LINES}).",
              },
            },
            "required" => ["id"],
          })
          DESCRIPTION =
            "Read the latest output of a process started with start_process, with its current " \
            "status; the default is the last #{DEFAULT_LINES} lines.".freeze

          def initialize(env:)
            @env = env
          end

          def call(args)
            table = @env.processes
            return unavailable if table.nil?

            id = args["id"].to_s
            count = args["tail_lines"].is_a?(Integer) ? args["tail_lines"].clamp(1, MAX_LINES) : DEFAULT_LINES
            # NotFound with the known ids; Gone with the exit; NotOwner by name.
            row = table.fetch(id, by: caller, conversation: caller_conversation)
            snapshot = row.snapshot
            lines = row.output.lines(count)
            lines = "(no output)" if lines.empty?
            Result.ok("#{render_row(snapshot)}\n\n#{lines}", snapshot.to_h)
          rescue Rho::Processes::Gone => error
            # THE DEAD CALL: the exit, the entry is gone, and the log file's tail under it — the
            # buffer left with the row.
            tail = Rho::Processes::Output.tail(error.snapshot.log_path, count)
            tail = "(no output)" if tail.empty?
            Result.error("#{error.message}\n\n#{tail}", error.snapshot.to_h)
          rescue Rho::Processes::Error => error
            Result.error(error.message)
          end
        end

        # THE PERSON'S READ OF ANY ROW: the same body as
        # the daemon's own log door (`Routes.read_log`) — one function, two
        # doors — with the `"user"` caller and NO owner gate. The model's
        # `read_process` fetches by the caller's conversation, and a call_tool
        # run is a standalone caller with none, so every conversation-owned
        # process (the only kind worth relaying) would answer `NotOwner`; a
        # person asking through `rho logs` is the person, and the daemon's
        # door already reads any row. That is the RECORDED semantic
        # difference (one implementation per mechanism) that keeps
        # the two tools apart; the model's stays byte-stable. Described to
        # nobody (`DESCRIPTION` nil): announced without a schema, hidden by
        # name on the agent side, never offered to a model.
        class ProcessLog
          include Shared

          NAME = "process_log"
          DESCRIPTION = nil
          EFFECT_PROFILE = READ_PROFILE
          SCHEMA = Ractor.make_shareable({
            "type" => "object",
            "properties" => {
              "id" => { "type" => "string", "description" => "The process id, e.g. p3." },
              "lines" => { "type" => "integer", "minimum" => 1, "maximum" => Routes::LOG_LINES_MAX,
                           "description" => "How many of the latest lines (default #{Routes::LOG_LINES})." },
            },
            "required" => ["id"],
          })

          def initialize(env:)
            @env = env
          end

          def call(args)
            table = @env.processes
            return unavailable if table.nil?

            id = args["id"].to_s
            count = args["lines"].is_a?(Integer) ? args["lines"] : Routes::LOG_LINES
            document = Routes.read_log(table, id, count)
            return Result.error("no process #{id}") if document.nil?

            text = document.fetch(:lines).empty? ? "(no output)" : document.fetch(:lines).join("\n")
            Result.ok("#{render_row(document.fetch(:snapshot))}\n\n#{text}", document.except(:snapshot))
          end
        end

        class StopProcess
          include Shared

          NAME = "stop_process"
          EFFECT_PROFILE = WRITE_PROFILE
          SCHEMA = Ractor.make_shareable({
            "type" => "object",
            "properties" => {
              "id" => { "type" => "string", "description" => "The process id from start_process, e.g. p3." },
            },
            "required" => ["id"],
          })
          DESCRIPTION =
            "Stop a process started with start_process: TERM, then KILL after a few seconds, " \
            "the whole process group. A process another run started can only be stopped by " \
            "that run or by the person (rho kill ID). An exited process is forgotten.".freeze

          def initialize(env:)
            @env = env
          end

          def call(args)
            table = @env.processes
            return unavailable if table.nil?

            snapshot = table.stop(args["id"].to_s, by: caller, conversation: caller_conversation)
            Result.ok("#{snapshot.label} stopped: exited with #{snapshot.exit_phrase}", snapshot.to_h)
          rescue Rho::Processes::Error => error
            Result.error(error.message)
          end
        end
      end
    end
  end
end
