module Rho
  module Processes
    # WHAT A PROCESS SAID, kept where a reader can always reach it.
    #
    # THE MEMORY IS THE SOURCE OF TRUTH; the file is a courtesy. A reader —
    # the model's read_process, the operator's `rho logs`, the environment
    # block — answers from a bounded buffer that no rotation, deletion or
    # ENOSPC can pull out from under it. The file on disk is for a human
    # with `tail -f`, written through, rotated once at a cap, and abandoned
    # (with the reason kept) the first time the disk says no.
    #
    # THE BUFFER IS A HEAD AND A TAIL. The first 64 KB is what a server
    # prints at startup — the address, the warnings — and the last 256 KB
    # is what it is doing now. What fell between is in the file.
    #
    # A LINE IS NOTED AS IT COMPLETES: the first non-empty one, the last,
    # and the first that contains what the caller said to wait for. The
    # whole buffer is never scanned for those; a busy server would make
    # every start_process wait quadratic.
    class Output
      HEAD_BYTES = 64 * 1024
      TAIL_BYTES = 256 * 1024
      ROTATE_AT_BYTES = 8 * 1024 * 1024
      LINE_LIMIT = 4 * 1024
      ANSI = /\e\[[0-9;?]*[ -\/]*[@-~]|\e[()][A-Za-z0-9]|\r/
      DROPPED = "[… %s of earlier output dropped; the log file has it …]".freeze

      attr_reader :path, :file_error

      # `on_line` hears every completed, cleaned line as it is noted — the
      # process pump's feed for the watcher's frames; it takes
      # the line and returns, under this buffer's mutex, so it must not
      # read back into here.
      def initialize(path:, wait_for: nil, rotate_at: ROTATE_AT_BYTES, on_line: nil)
        @path = path
        @wait_for = wait_for.to_s.empty? ? nil : wait_for.to_s.downcase
        @rotate_at = rotate_at
        @on_line = on_line
        @mutex = Mutex.new
        @head = String.new(encoding: Encoding::BINARY)
        @tail = String.new(encoding: Encoding::BINARY)
        @partial = String.new(encoding: Encoding::BINARY)
        @dropped = 0
        @total = 0
        @first_line = nil
        @ready_line = nil
        @last_line = nil
        @eof = false
        @file = nil
        @file_bytes = 0
        @file_error = nil
      end

      def append(chunk)
        @mutex.synchronize do
          @total += chunk.bytesize
          keep(chunk)
          scan(chunk)
          mirror(chunk)
        end
      end

      # The writers are gone. Whatever was mid-line is a line now.
      def eof!
        @mutex.synchronize do
          @eof = true
          note(@partial) unless @partial.empty?
          @partial = String.new(encoding: Encoding::BINARY)
          close_file
        end
      end

      # THE EXIT FACT, IN THE FILE: once the group is dead the entry leaves the table, so the
      # file is what keeps how it ended. An append on a file `eof!` already closed — or
      # rotated — reopened once for the one line; a file the disk refused stays refused.
      def note_exit(line)
        @mutex.synchronize do
          next if @file_error

          File.open(@path, "ab") { |file| file.write("#{line}\n") }
        rescue SystemCallError, IOError => error
          @file_error = "#{error.class}: #{error.message}"
        end
      end

      # THE FILE'S TAIL, for a reader whose buffer is gone with its row: the
      # last `count` lines of at most `max_bytes`, cleaned the way `lines`
      # cleans; empty for a file that is not there.
      def self.tail(path, count, max_bytes: Rho::Runner::Truncation::DEFAULT_MAX_BYTES)
        text = File.open(path, "rb") do |file|
          file.seek([file.size - max_bytes, 0].max)
          file.read.to_s
        end
        cleaned = text.force_encoding(Encoding::UTF_8).scrub("?").gsub(ANSI, "")
        cleaned.lines.last(count).map(&:chomp).join("\n")
      rescue SystemCallError, IOError
        ""
      end

      def eof? = @mutex.synchronize { @eof }
      def matched? = @mutex.synchronize { !@ready_line.nil? }
      def first_line = @mutex.synchronize { @first_line }
      def last_line = @mutex.synchronize { @last_line }

      # The line to show for "what is it saying": the one that matched, else
      # the first thing it printed.
      def ready_line = @mutex.synchronize { @ready_line || @first_line }

      # The last `count` lines, ANSI-stripped, never more than `max_bytes` —
      # the runner's one output bound (`Truncation::DEFAULT_MAX_BYTES`, read
      # by name: a process read defends the model's context as a tool's
      # result does; the dropped note's size is that module's `format_size`
      # too); a cut is made at a line boundary so no reader sees half a
      # line.
      def lines(count, max_bytes: Rho::Runner::Truncation::DEFAULT_MAX_BYTES)
        text = @mutex.synchronize { render }
        selected = text.lines.last(count).map(&:chomp).join("\n")
        return selected if selected.bytesize <= max_bytes

        cut = selected.byteslice(-max_bytes, max_bytes).scrub("")
        cut.sub(/\A[^\n]*\n/, "")
      end

      private

        def keep(chunk)
          room = HEAD_BYTES - @head.bytesize
          if room.positive?
            @head << chunk.byteslice(0, room)
            chunk = chunk.byteslice(room, chunk.bytesize) || String.new(encoding: Encoding::BINARY)
          end
          return if chunk.empty?

          @tail << chunk
          overflow = @tail.bytesize - TAIL_BYTES
          return unless overflow.positive?

          # Drop through the next newline, so the tail begins on a line.
          cut = (@tail.index("\n", overflow) || (overflow - 1)) + 1
          @dropped += cut
          @tail = @tail.byteslice(cut, @tail.bytesize) || String.new(encoding: Encoding::BINARY)
        end

        def scan(chunk)
          @partial << chunk
          while (newline = @partial.index("\n"))
            note(@partial.byteslice(0, newline))
            @partial = @partial.byteslice(newline + 1, @partial.bytesize) || String.new(encoding: Encoding::BINARY)
          end
          # A progress bar redraws one line forever with \r; keep its end.
          return unless @partial.bytesize > LINE_LIMIT * 4

          @partial = @partial.byteslice(-LINE_LIMIT, LINE_LIMIT)
        end

        def note(raw)
          line = clean(raw)
          return if line.empty?

          @first_line ||= line
          @last_line = line
          @ready_line ||= line if @wait_for && line.downcase.include?(@wait_for)
          @on_line&.call(line)
        end

        def clean(raw)
          text = raw.dup.force_encoding(Encoding::UTF_8).scrub("?").gsub(ANSI, "").strip
          text.bytesize > LINE_LIMIT ? text.byteslice(0, LINE_LIMIT).scrub("") : text
        end

        def render
          text = String.new(encoding: Encoding::BINARY)
          text << @head
          text << "\n#{format(DROPPED, Rho::Runner::Truncation.format_size(@dropped))}\n" if @dropped.positive?
          text << @tail
          text.force_encoding(Encoding::UTF_8).scrub("?").gsub(ANSI, "")
        end

        def mirror(chunk)
          return if @file_error

          @file ||= open_file
          @file.write(chunk)
          @file_bytes += chunk.bytesize
          rotate if @file_bytes >= @rotate_at
        rescue SystemCallError, IOError => error
          @file_error = "#{error.class}: #{error.message}"
          close_file
        end

        def open_file
          File.open(@path, "ab").tap { |file| file.sync = true }
        end

        def rotate
          close_file
          File.rename(@path, "#{@path}.1")
          @file_bytes = 0
        end

        def close_file
          @file&.close
        rescue IOError
          nil
        ensure
          @file = nil
        end
    end
  end
end
