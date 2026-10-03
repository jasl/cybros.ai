require "rho/runner"

module Rho
  module Processes
    # WHAT A PROCESS IS PRINTING, for whoever is watching (executor.md "Progress"): the completed lines of every live row in the
    # daemon's own table, posted as `process_output` frames keyed by the
    # row's HOST — the conversation the kernel named on the inbox row, else
    # the loop itself — at the kernel's cadence, line-batched, one frame per
    # row per tick, and a last frame carrying the exit when the group ends.
    #
    # GATED ON THE TABLE, never on "while the host is followed": a
    # runner-mode rho holds no member credential and follows nothing, so a
    # follow gate would never fire on the separated runner; the registry
    # feeds this from the rows it holds, and the kernel's binding fence
    # (`not_bound`) is the only other gate. A frame is droppable by
    # construction: a refusal for a row ends that row's posting (logged
    # once), a transport blip drops that tick's lines, a printer faster
    # than the buffer loses its oldest lines — and never a process.
    #
    # `post` is the daemon's: it hands the frame to the runner slot of the
    # moment and answers false when there is none (an agent-mode rho is
    # never a binding), so nothing is posted and nothing is logged.
    class Pump
      # THE SERVER'S ENVELOPE BOUND, MIRRORED with headroom (the daemon
      # cannot read nexus's size registry; `size_bounds.json`'s
      # `envelope_bound` is 64 KiB): the key, the stamps and the JSON
      # escaping of `lines` ride inside it, so a frame's lines stop here.
      FRAME_LINE_BYTES = 48 * 1024
      # Lines kept per row between ticks: a printer that outruns the
      # cadence loses its OLDEST lines, and the frame says so.
      BUFFER_LINES = 512
      DROPPED = "[… %d earlier lines dropped: the process outran the frame cadence …]".freeze

      Entry = Struct.new(:host, :lines, :dropped, :exit, :exited, :denied)

      attr_reader :interval_ms

      def initialize(post:, log: nil, interval_ms: Rho::Runner::Progress::MIN_INTERVAL_MS,
                     sleeper: ->(seconds) { sleep(seconds) })
        raise ArgumentError, "interval_ms must be positive" unless interval_ms.positive?

        @post = post
        @log = log
        @interval_ms = interval_ms
        @sleeper = sleeper
        @mutex = Mutex.new
        @entries = {}
        @closed = false
      end

      # FROM THE REGISTRY'S PUMP THREAD: one completed line of one row.
      # `host` is the row's key on the wire — `{"conversation_public_id"
      # => …}` or `{"agent_loop_public_id" => …}` — nil for a row the
      # person started, which no host's feed carries.
      def line(id, host, text)
        return if host.nil?

        @mutex.synchronize do
          entry = (@entries[id] ||= Entry.new(host, [], 0, nil, false, false))
          next if entry.denied

          entry.lines << text
          next unless entry.lines.length > BUFFER_LINES

          entry.dropped += 1
          entry.lines.shift
        end
        nil
      end

      # THE GROUP ENDED: the next tick posts what is left with the exit —
      # an Integer status, or nil for a signal death — and forgets the row.
      def exited(id, host, status)
        return if host.nil?

        @mutex.synchronize do
          entry = (@entries[id] ||= Entry.new(host, [], 0, nil, false, false))
          entry.exit = status
          entry.exited = true
        end
        nil
      end

      def closed? = @mutex.synchronize { @closed }

      def close
        @mutex.synchronize { @closed = true }
        nil
      end

      # THE DAEMON'S BACKGROUND TASK: one tick per interval for the
      # daemon's life; ends when the table closes.
      def run
        until closed?
          @sleeper.call(@interval_ms / 1000.0)
          break if closed?

          tick
        end
        nil
      end

      # ONE TICK: every row with lines or an exit posts one frame; answers
      # how many went out. Public so a test drives it without the clock.
      def tick
        taken = @mutex.synchronize do
          @entries.filter_map do |id, entry|
            next if entry.denied || (entry.lines.empty? && !entry.exited)

            frame = frame_for(id, entry)
            entry.lines = []
            entry.dropped = 0
            [id, frame, entry]
          end
        end
        taken.count { |id, frame, entry| post(id, frame, entry) }
      end

      private

        def frame_for(id, entry)
          lines = bounded(entry.lines)
          lines.unshift(format(DROPPED, entry.dropped)) if entry.dropped.positive?
          frame = entry.host.merge("process_id" => id, "lines" => lines)
          frame["exit"] = entry.exit if entry.exited
          frame
        end

        # The NEWEST lines that fit the frame: the tail is what a watcher
        # wants, and the oldest is what a bound drops.
        def bounded(lines)
          kept = []
          bytes = 0
          lines.reverse_each do |line|
            bytes += line.bytesize + 1
            break if bytes > FRAME_LINE_BYTES

            kept.unshift(line)
          end
          kept
        end

        def post(id, frame, entry)
          sent = @post.call(frame)
          forget(id) if entry.exited
          sent ? true : false
        rescue CybrosAgent::Api::Conflict => error
          # `not_bound`: this runner is not the host's binding — nothing
          # this row prints is this feed's to carry, so the row's posting
          # ends here, said once.
          @log&.warn("processes.progress_refused", id: id, code: error.code)
          @mutex.synchronize { entry.denied = true }
          forget(id) if entry.exited
          false
        rescue CybrosAgent::Error => error
          # A frame is droppable: this tick's lines are lost, the next
          # tick tries again with what came after.
          @log&.info("processes.progress_dropped", id: id, error_class: error.class.name,
            error: CybrosAgent::Redaction.call(error.message))
          forget(id) if entry.exited
          false
        end

        def forget(id) = @mutex.synchronize { @entries.delete(id) }
    end
  end
end
