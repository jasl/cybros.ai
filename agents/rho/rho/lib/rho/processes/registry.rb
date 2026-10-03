require "fileutils"
require "time"

module Rho
  module Processes
    # A PROCESS, AS EVERY READER SEES IT. Frozen, JSON-shaped, and one object for the tool
    # answer, the route, the CLI line and the UI. `owner` is the CONVERSATION the starting
    # loop belonged to — the loop's own id when the daemon could not place it — and `loop`
    # the loop that called, kept for display.
    Snapshot = Data.define(
      :id, :name, :command, :workdir, :owner, :loop, :pid, :started_at, :status, :exit_status,
      :signal, :stopped_by, :ready_line, :last_line, :log_path, :leader_exited, :output_open
    ) do
      def live? = status != "exited"
      def label = name ? "#{id} (#{name})" : id

      def exit_phrase
        return "status #{exit_status}" unless exit_status.nil?
        return "signal #{signal}" if signal

        "an unknown status"
      end

      # How it ended, in the words every reader shares: the owner's notice,
      # the dead-call answer, the log file's exit line.
      def how
        case stopped_by
        when nil then "on its own"
        when "user" then "stopped by the person"
        when "shutdown" then "stopped by the daemon shutting down"
        when CONVERSATION_ENDED then "stopped when its conversation ended here"
        else "stopped by loop #{stopped_by}"
        end
      end

      def to_h = super.transform_keys(&:to_s).merge("started_at" => started_at.iso8601)
    end

    # The `stopped_by` a conversation's end writes: never a loop, never the person.
    CONVERSATION_ENDED = "conversation_ended".freeze

    # THE REGISTRY'S OWN VIEW: mutable, and only under its mutex.
    class Row
      attr_reader :id, :name, :command, :workdir, :owner, :loop, :process, :started_at, :output
      attr_accessor :stopped_by, :stopper, :stopping_since, :noticed

      def initialize(id:, name:, command:, workdir:, owner:, loop:, process:, started_at:, output:, stdin:)
        @id = id
        @name = name
        @command = command
        @workdir = workdir
        @owner = owner
        @loop = loop
        @process = process
        @started_at = started_at
        @output = output
        @stdin = stdin
        @stopped_by = nil
        @stopper = nil
        @stopping_since = nil
        @noticed = false
      end

      def pid = process.pid
      def pgid = process.group_pid
      def exit_status = process.poll
      def leader_exited? = !exit_status.nil?

      # THE UNIT IS THE GROUP. A leader that exited 0 after backgrounding
      # the real server left descendants holding the output pipe: as long
      # as the pipe is open, something is still running in this group.
      def live? = !leader_exited? || !output.eof?
      def stopping? = !stopping_since.nil? && live?
      def label = name ? "#{id} (#{name})" : id

      def release_stdin
        @stdin.close unless @stdin.closed?
      rescue IOError
        nil
      end

      def snapshot
        status = exit_status
        Snapshot.new(
          id:, name:, command:, workdir:, owner:, loop:, pid:, started_at:,
          status: live? ? (stopping? ? "stopping" : "running") : "exited",
          exit_status: status&.exitstatus,
          signal: status&.termsig && Signal.signame(status.termsig),
          stopped_by:, ready_line: output.ready_line, last_line: output.last_line,
          log_path: output.path, leader_exited: leader_exited?, output_open: !output.eof?
        )
      end
    end

    # THE PROCESSES THIS DAEMON OWNS — what a background task IS, by the product's
    # definition: something the person can see and stop, not something that merely takes a
    # long time. Started by a loop through start_process, listed and killed by the loop or
    # the person, alive for the daemon's lifetime and never past it.
    #
    # THE LIFECYCLE FOLLOWS THE CONVERSATION. An entry's owner is the conversation of the loop that
    # started it — the kernel's word on the inbox row (`conversation_public_id`,
    # nil for a standalone loop), carried by the execution context — and a
    # loop it cannot place owns by its own id — so every loop of that
    # conversation reads and stops it and no other conversation's may.
    # When the conversation ends for this runner the daemon calls
    # `release`, which kills the groups and removes the entries.
    #
    # THE TABLE STAYS TRUTHFUL BY TWO PATHS. A group that died leaves the
    # table the moment its pipe closes (`settle`), and a bounded EXIT
    # MEMORY answers the next call against its id with the exit and "the
    # entry is gone" (`Gone`), so a restart is `start_process` again under
    # a new id; the periodic `sweep_dead!` is the fallback that removes
    # whatever a pump missed. The exit fact is also the log file's last
    # line. The state file persists only live rows: a restart never
    # resurrects an entry.
    #
    # LIVENESS IS THE GROUP'S, not the leader's. Every exit path — a stop,
    # a release, shutdown — signals the whole group, TERM then KILL, and
    # only then reaps the group's identity guard. A leader that died
    # leaving a server behind is still "running" here until the server
    # is gone too, because the port and the pipe are the server's.
    #
    # NO STDIN, NO TTY, ever. The child gets the read end of a pipe the
    # daemon holds open and never writes: no data, and no EOF either — a
    # dev server that exits when stdin closes (create-react-app, older
    # webpack-dev-server) stays up, and no ANSI spinner storm reaches the
    # log the way a pty would invite.
    #
    # A DAEMON THAT DIES WITHOUT STOPPING leaves the rows in a state file;
    # the next boot finds and reaps what is verifiably still the same
    # group, and says so once.
    class Registry
      LIVE_CAP = 8
      EXITED_KEEP = 8
      STOP_GRACE = 5.0
      SHUTDOWN_GRACE = 2.0
      EOF_WAIT = 1.0
      POLL = 0.05
      SWEEP_SECONDS = 30.0
      SHELL = "/bin/bash"
      READ_CHUNK = 64 * 1024

      attr_reader :log_dir, :progress

      # `progress` is the watcher's channel (`Pump`): every live
      # row's completed lines and its exit, posted under the row's HOST at
      # the kernel's cadence — fed from this table alone, which is the gate.
      def initialize(log_dir:, state_file:, log: nil, live_cap: LIVE_CAP, progress: nil)
        @log_dir = log_dir
        @state_file = state_file
        @log = log
        @live_cap = live_cap
        @progress = progress
        @mutex = Mutex.new
        @rows = {}
        @exits = {}
        @sequence = 0
        @reserved = 0
        @closed = false
        @notices = Hash.new { |hash, key| hash[key] = [] }
        @orphans = []
      end

      def any_live? = @mutex.synchronize { @rows.values.any?(&:live?) }
      def snapshots = @mutex.synchronize { @rows.values.map(&:snapshot) }
      def row(id) = @mutex.synchronize { @rows[id] }
      def exit_of(id) = @mutex.synchronize { @exits[id] }
      def closed? = @mutex.synchronize { @closed }

      # THE ROW A CALLER MAY READ: the person always, a loop only what its
      # conversation started. `by` is the caller (a loop id, or `user`),
      # `conversation` the caller's conversation as the inbox row named it
      # — nil for a standalone loop, which owns by its own id. Unknown is
      # NotFound with the live ids; a group that died is Gone with the exit
      # (the dead-call answer).
      def fetch(id, by:, conversation: nil)
        caller = owner_for(by.to_s, conversation)
        row = @mutex.synchronize do
          found = @rows[id] || raise_missing(id)
          raise NotOwner, not_owner_message(found, "read") unless may_touch?(found, caller)

          found
        end
        raise_gone(row) unless row.live?
        row
      end

      # RESERVE, SPAWN, COMMIT. The slot and the id are taken under the
      # mutex, the spawn happens outside it (it blocks), and the commit
      # re-checks `closed`: a shutdown that raced the spawn kills what was
      # just started rather than registering into a swept table.
      def start(command:, workdir:, env:, name: nil, loop: nil, conversation: nil, wait_for: nil)
        id = reserve!
        row =
          begin
            spawn_row(id, command:, workdir:, env:, name:, loop:, conversation:, wait_for:)
          rescue SystemCallError, ArgumentError, TypeError => error
            @mutex.synchronize { @reserved -= 1 }
            raise Error, "could not start #{command.inspect}: #{error.message}"
          end
        commit(row)
      end

      # TERM, a grace, then KILL to the group — and the answer is the final
      # state. `wait: false` stamps and TERMs now and finishes the ladder
      # on its own thread: the daemon's route must not stall its reactor.
      def stop(id, by:, conversation: nil, grace: STOP_GRACE, wait: true)
        row = stamp_stop(id, by, conversation)
        if wait
          ladder(row, grace)
          persist
        else
          row.process.terminate("TERM")
          Thread.new do
            ladder(row, grace)
            persist
          end
        end
        row.snapshot
      end

      # THE CONVERSATION ENDED FOR THIS RUNNER: every live group it owns is TERMed now and
      # laddered to KILL on its own thread — the caller is the daemon's reactor, which must
      # not wait a grace — and each entry is retired from that thread's tail. Answers the ids.
      def release(owner, grace: STOP_GRACE)
        return [] if owner.nil?

        rows = @mutex.synchronize do
          @rows.values.select { |row| row.owner == owner && row.live? }.each do |row|
            row.stopped_by ||= CONVERSATION_ENDED
            row.stopper ||= owner
            row.stopping_since ||= monotonic
            row.noticed = true
          end
        end
        return [] if rows.empty?

        @log&.info("processes.released", owner: owner, ids: rows.map(&:id))
        rows.each { |row| row.process.terminate("TERM") }
        Thread.new do
          rows.each do |row|
            ladder(row, grace)
            retire(row)
          end
          persist
        end
        rows.map(&:id)
      end

      # THE FALLBACK: every group that is no longer alive leaves the table; a live one is
      # never touched. Answers what it retired.
      def sweep_dead!
        rows = @mutex.synchronize { @rows.values }
        retired = rows.filter_map { |row| retire(row) }
        persist unless retired.empty?
        retired
      end

      # ONE TERM BROADCAST, ONE BOUNDED WAIT, ONE KILL BROADCAST. Nothing
      # new can start from the moment the latch flips.
      def close
        live = @mutex.synchronize do
          @closed = true
          @rows.values.select(&:live?).each do |row|
            row.stopped_by ||= "shutdown"
            row.stopping_since ||= monotonic
          end
        end
        live.each { |row| row.process.terminate("TERM") }
        wait_until(SHUTDOWN_GRACE) { live.all?(&:leader_exited?) }
        live.each do |row|
          row.process.kill_and_reap
          row.release_stdin
        end
        delete_state
        @progress&.close
        live.map(&:snapshot)
      end

      # THE PREVIOUS DAEMON'S PROCESSES, if it died without stopping. Only
      # a group whose recorded leader still sits in its recorded group is
      # signalled: a PID that moved on belongs to somebody else now.
      def sweep_orphans
        document = @state_file.read
        rows = Array(document && document["processes"])
        delete_state
        reaped = rows.filter_map { |recorded| reap_orphan(recorded) }
        @mutex.synchronize { @orphans = reaped }
        unless reaped.empty?
          @log&.info("processes.orphans_reaped", count: reaped.size, ids: reaped.map { |r| r["id"] })
        end
        reaped
      rescue Rho::StateError => error
        @log&.warn("processes.state_unreadable", detail: error.message)
        []
      end

      def take_orphans
        @mutex.synchronize do
          taken = @orphans
          @orphans = []
          taken
        end
      end

      # WHAT A CONVERSATION IS TOLD, once, about a process it did not stop
      # itself — through whichever of its loops asks next.
      def take_notices(loop, conversation: nil)
        owner = owner_for(loop, conversation)
        return [] if owner.nil?

        @mutex.synchronize { @notices.key?(owner) ? @notices.delete(owner) : [] }
      end

      private

        def reserve!
          @mutex.synchronize do
            raise Closed, "the daemon is stopping; nothing new can be started" if @closed

            live = @rows.values.count(&:live?) + @reserved
            raise Full, full_message if live >= @live_cap

            @reserved += 1
            "p#{@sequence += 1}"
          end
        end

        def full_message
          listing = @rows.values.select(&:live?).map { |row| "  #{row.label}: #{row.command}" }.join("\n")
          "#{@live_cap} processes are already running, which is the limit; " \
            "stop one with stop_process first:\n#{listing}"
        end

        # WHOSE A LOOP IS: the conversation the kernel named on the row,
        # else the loop itself (a standalone loop is its own host); the
        # person is the person. Nothing is resolved or cached here — the
        # row is the fact, and every call carries it.
        def owner_for(loop, conversation)
          return nil if loop.nil?
          return loop if loop == "user"

          conversation || loop
        end

        # THE ROW'S HOST ON THE WIRE: the
        # conversation the kernel named, else the loop itself — the host
        # whose `progress` feed carries this row's output; nil for a row
        # the person started or nobody owns, which no feed carries.
        def host_key(loop, conversation)
          return { "conversation_public_id" => conversation } if conversation
          return nil if loop.nil? || loop == "user"

          { "agent_loop_public_id" => loop }
        end

        def spawn_row(id, command:, workdir:, env:, name:, loop:, conversation:, wait_for:)
          owner = owner_for(loop, conversation)
          host = host_key(loop, conversation)
          FileUtils.mkdir_p(@log_dir)
          output = Output.new(path: File.join(@log_dir, "#{id}.log"), wait_for:,
            on_line: (@progress && ->(line) { @progress.line(id, host, line) }))
          stdin_reader, stdin_writer = IO.pipe
          out_reader, out_writer = IO.pipe
          out_reader.binmode
          process = Rho::Runner::OwnedProcess.spawn(
            env, SHELL, "-c", command,
            chdir: workdir, in: stdin_reader, out: out_writer, err: out_writer, unsetenv_others: true
          )
          row = Row.new(
            id:, name:, command:, workdir:, owner:, loop:, process:, started_at: Time.now, output:,
            stdin: stdin_writer
          )
          Thread.new { pump(row, out_reader) }
          row
        ensure
          stdin_reader&.close
          out_writer&.close
          if process.nil?
            stdin_writer&.close
            out_reader&.close
          end
        end

        def commit(row)
          admitted = @mutex.synchronize do
            @reserved -= 1
            @rows[row.id] = row unless @closed
            !@closed
          end
          unless admitted
            row.process.kill_and_reap
            row.release_stdin
            raise Closed, "the daemon is stopping; nothing new can be started"
          end
          persist
          row
        end

        def pump(row, reader)
          loop { row.output.append(reader.readpartial(READ_CHUNK)) }
        rescue EOFError, IOError
          nil
        ensure
          begin
            reader.close unless reader.closed?
          rescue IOError
            nil
          end
          row.output.eof!
          settle(row)
        end

        # THE PIPE CLOSED: the group is dead the moment this runs, so the
        # entry leaves the table here, event-driven; the sweep is for what
        # this missed.
        def settle(row)
          retire(row)
          persist
        end

        # THE ONE EXIT, under the mutex, exactly once: the row leaves the
        # table, its exit is remembered for the dead-call answer, the
        # owner is told if it was not the one who ended it; then the log
        # file gets its last line. Answers the exit snapshot, or nil for a
        # group still alive or already retired.
        def retire(row)
          row.process.poll
          snapshot = @mutex.synchronize do
            next nil if row.live? || !@rows.key?(row.id)

            @rows.delete(row.id)
            taken = row.snapshot
            remember_exit(taken)
            unless row.noticed || row.owner.nil? || row.stopper == row.owner
              row.noticed = true
              @notices[row.owner] << notice_for(taken)
            end
            taken
          end
          return nil if snapshot.nil?

          row.release_stdin
          row.output.note_exit(exit_line(snapshot))
          @progress&.exited(row.id, host_key(row.loop, row.owner == row.loop ? nil : row.owner), snapshot.exit_status)
          snapshot
        end

        # Bounded, oldest first: a crash-retry loop must not fill the
        # memory with corpses, and the oldest corpse is the least useful.
        def remember_exit(snapshot)
          @exits.delete(snapshot.id)
          @exits[snapshot.id] = snapshot
          @exits.shift while @exits.size > EXITED_KEEP
        end

        def notice_for(snapshot)
          "NOTE: process #{snapshot.label} (pid #{snapshot.pid}) exited with #{snapshot.exit_phrase}, " \
            "#{snapshot.how}. Its log: #{snapshot.log_path}"
        end

        # The leader's status and the GROUP's end are two facts, and a
        # leader that exited while a child held the pipe makes them differ
        # in time: the line names both.
        def exit_line(snapshot)
          "[rho] #{snapshot.label}: leader exited with #{snapshot.exit_phrase}, #{snapshot.how}; " \
            "the group ended at #{Time.now.utc.iso8601}"
        end

        # THE DEAD-CALL ANSWER: the one model-facing sentence.
        def gone_message(snapshot)
          "#{snapshot.label} exited with #{snapshot.exit_phrase}, #{snapshot.how}; the entry is gone — " \
            "start_process again gives a new id. Its log: #{snapshot.log_path}"
        end

        # A row found dead: retired here if a pump has not done it yet,
        # and the answer is its exit either way.
        def raise_gone(row)
          snapshot = retire(row) || exit_of(row.id) || row.snapshot
          raise Gone.new(gone_message(snapshot), snapshot: snapshot)
        end

        # Under the mutex: a remembered exit is Gone, anything else is the
        # not-found with the live ids.
        def raise_missing(id)
          remembered = @exits[id]
          raise Gone.new(gone_message(remembered), snapshot: remembered) if remembered

          known = @rows.keys
          raise NotFound, "no process #{id}; nothing has been started" if known.empty?

          raise NotFound, "no process #{id}; known: #{known.join(", ")}"
        end

        def stamp_stop(id, by, conversation)
          caller = owner_for(by.to_s, conversation)
          row = @mutex.synchronize do
            found = @rows[id] || raise_missing(id)
            if found.live?
              raise NotOwner, not_owner_message(found, "stop") unless may_touch?(found, caller)

              found.stopped_by ||= by.to_s
              found.stopper ||= caller
              found.stopping_since ||= monotonic
            end
            found
          end
          raise_gone(row) unless row.live?
          row
        end

        def may_touch?(row, caller)
          caller == "user" || row.owner.nil? || row.owner == caller
        end

        def not_owner_message(row, verb)
          if row.owner == row.loop
            "#{row.label} belongs to loop #{row.owner}; only that loop, or the person (rho kill #{row.id}), may #{verb} it"
          else
            "#{row.label} belongs to conversation #{row.owner}; only its loops, or the person (rho kill #{row.id}), " \
              "may #{verb} it"
          end
        end

        def ladder(row, grace)
          row.process.terminate("TERM")
          wait_until(grace) { row.leader_exited? }
          row.process.kill_and_reap
          wait_until(EOF_WAIT) { row.output.eof? }
          row.release_stdin
        end

        def wait_until(seconds)
          deadline = monotonic + seconds
          until yield
            return false if monotonic >= deadline

            sleep POLL
          end
          true
        end

        def reap_orphan(recorded)
          pid = Integer(recorded.fetch("pid"))
          pgid = Integer(recorded.fetch("pgid"))
          return nil unless Process.getpgid(pid) == pgid

          Process.kill("TERM", -pgid)
          wait_until(SHUTDOWN_GRACE) { group_gone?(pgid) }
          signal_group("KILL", pgid) unless group_gone?(pgid)
          recorded.merge("reaped" => true)
        rescue Errno::ESRCH, Errno::EPERM, ArgumentError, TypeError, KeyError
          nil
        end

        # ESRCH is an empty group. EPERM is a group with nothing left that
        # can take a signal — on macOS, one whose every member is a zombie
        # — which for the sweep is the same news.
        def group_gone?(pgid)
          Process.kill(0, -pgid)
          false
        rescue Errno::ESRCH, Errno::EPERM
          true
        end

        def signal_group(signal, pgid)
          Process.kill(signal, -pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        def persist
          rows = @mutex.synchronize do
            next nil if @closed

            @rows.values.select(&:live?).map do |row|
              { "id" => row.id, "pid" => row.pid, "pgid" => row.pgid, "command" => row.command,
                "started_at" => row.started_at.iso8601 }
            end
          end
          return if rows.nil?

          @state_file.write("processes" => rows)
        rescue StandardError => error
          @log&.warn("processes.persist_failed", error_class: error.class.name, detail: error.message)
        end

        def delete_state
          @state_file.delete
        rescue StandardError => error
          @log&.warn("processes.persist_failed", error_class: error.class.name, detail: error.message)
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
