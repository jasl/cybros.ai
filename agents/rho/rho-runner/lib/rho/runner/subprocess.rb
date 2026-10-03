module Rho
  class Runner
    # Owns command pipes and the command's guarded process group. All exit
    # paths tear down the full group, reap both owned children, and settle
    # pipe readers.
    class Subprocess
      MAX_STDOUT_LINE_BYTES = Truncation::DEFAULT_MAX_BYTES
      MAX_STDERR_BYTES = Truncation::DEFAULT_MAX_BYTES

      OutputLine = Data.define(:content, :truncated)
      Capture = Data.define(:content, :truncated, :max_bytes)

      attr_reader :stdin, :stdout, :stderr, :pid

      def self.start(*argv)
        child_stdin, stdin = IO.pipe
        stdout, child_stdout = IO.pipe
        stderr, child_stderr = IO.pipe
        process = OwnedProcess.spawn(*argv, in: child_stdin, out: child_stdout, err: child_stderr)
        [child_stdin, child_stdout, child_stderr].each(&:close)
        new(stdin:, stdout:, stderr:, process:)
      rescue Exception
        [child_stdin, stdin, stdout, child_stdout, stderr, child_stderr].compact.each do |io|
          io.close unless io.closed?
        rescue IOError
          nil
        end
        raise
      end

      def initialize(stdin:, stdout:, stderr:, process:)
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
        @process = process
        @pid = process.pid
        @stderr_capture = BoundedCapture.new(stderr, max_bytes: MAX_STDERR_BYTES)
        @cleaned = false
      end

      def each_stdout_line(max_bytes: MAX_STDOUT_LINE_BYTES, &)
        BoundedLineReader.new(stdout, max_bytes:).each(&)
      end

      def wait
        @process.wait
      end

      def kill_and_reap
        @process.kill_and_reap
      end

      # Cancellation callbacks run on the reactor thread. Signal only; the
      # worker's ensure path owns the potentially blocking reap.
      def cancel
        @process.cancel
      end

      def stderr_text
        capture = @stderr_capture.finish
        return capture.content unless capture.truncated

        notice = "[stderr truncated after #{capture.max_bytes} bytes]"
        capture.content.empty? ? notice : "#{capture.content}\n#{notice}"
      end

      # The predecessor deferred this when it found itself inside an Async
      # task, because its handlers could run on the reactor. Ours cannot:
      # a tool handler runs on a native worker and nothing else does, which
      # is the whole reason the pool exists. Carrying the guard would have
      # cost rho-runner a dependency on async purely to check a condition
      # that is always false here.
      def cleanup
        return if @cleaned

        perform_cleanup
      end

      private

      def perform_cleanup
        kill_and_reap
        @stderr_capture.finish
        close_streams
        @cleaned = true
      end

      def close_streams
        [stdin, stdout, stderr].each do |stream|
          stream.close unless stream.closed?
        rescue IOError
          nil
        end
      end

      class BoundedLineReader
        CHUNK_BYTES = 16 * 1024

        def initialize(io, max_bytes:)
          @io = io
          @max_bytes = max_bytes
        end

        def each
          return enum_for(__method__) unless block_given?

          buffer = +"".b
          truncated = false
          pending = false

          while (chunk = @io.read(CHUNK_BYTES))
            offset = 0
            while (newline = chunk.index("\n", offset))
              segment = chunk.byteslice(offset, newline - offset)
              truncated = append(buffer, segment) || truncated
              yield build_line(buffer, truncated)
              buffer = +"".b
              truncated = false
              pending = false
              offset = newline + 1
            end

            remainder = chunk.byteslice(offset..)
            unless remainder.empty?
              truncated = append(buffer, remainder) || truncated
              pending = true
            end
          end

          yield build_line(buffer, truncated) if pending
        end

        private

        def append(buffer, segment)
          remaining = @max_bytes - buffer.bytesize
          buffer << segment.byteslice(0, remaining) if remaining.positive?
          segment.bytesize > remaining
        end

        def build_line(buffer, truncated)
          content = buffer.dup.force_encoding(Encoding::UTF_8).scrub.freeze
          OutputLine.new(content:, truncated:)
        end
      end
      private_constant :BoundedLineReader

      class BoundedCapture
        CHUNK_BYTES = 16 * 1024

        def initialize(io, max_bytes:)
          @io = io
          @max_bytes = max_bytes
          @content = +"".b
          @truncated = false
          @finished_reader, @finished_writer = IO.pipe
          @thread = Thread.new { run }
        rescue Exception
          [@finished_reader, @finished_writer].compact.each(&:close)
          raise
        end

        def finish
          return @result if @result

          @finished_writer.close unless @finished_writer.closed?
          begin
            @thread.join
          ensure
            @io.close unless @io.closed?
          end
          content = @content.force_encoding(Encoding::UTF_8).scrub.freeze
          @result = Capture.new(content:, truncated: @truncated, max_bytes: @max_bytes)
        end

        private

        def run
          finished = false
          loop do
            unless finished
              readable = IO.select([@io, @finished_reader]).first
              finished = readable.include?(@finished_reader)
            end
            break if finished && @truncated

            # Reaping the command does not mean its reader has run yet.
            # Drain its queued bytes before closing, but never wait for a
            # detached writer's EOF or let continued output prolong cleanup.
            bytes = finished ? [CHUNK_BYTES, @max_bytes - @content.bytesize + 1].min : CHUNK_BYTES
            chunk = @io.read_nonblock(bytes, exception: false)
            break if chunk.nil? || (finished && chunk == :wait_readable)

            append(chunk) unless chunk == :wait_readable
          end
        rescue IOError, Errno::EBADF
          nil
        ensure
          @finished_reader.close unless @finished_reader.closed?
        end

        def append(chunk)
          remaining = @max_bytes - @content.bytesize
          @content << chunk.byteslice(0, remaining) if remaining.positive?
          @truncated = true if chunk.bytesize > remaining
        end
      end
      private_constant :BoundedCapture
    end
  end
end
