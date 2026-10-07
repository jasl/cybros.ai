require "shellwords"
require "stringio"

module Rho
  class Runner
    module Tools
      # Ported from pi's read.ts: offset/limit paging over the shared
      # head-truncation engine, with continuation markers teaching the model
      # how to keep going; invalid UTF-8 bytes are scrubbed, not fatal. An
      # image or PDF is answered as a capture (`Result#files`, the one upload site
      # in `TaskRun#submit`): the text names the file, the link beside it
      # is the kernel's to place natively or index — every reference reads
      # its native media through the same `read`. The kernel chooses native
      # placement or a file reference from the selected model's capabilities.
      class Read
        NAME = "read"
        # Pure filesystem read.
        EFFECT_PROFILE = {
          "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        }.freeze

        ScanResult = Data.define(:truncation, :total_file_lines, :first_line_bytes)

        # Fixed-size scanning keeps both ordinary large files and a single
        # unbroken line memory-bounded. Only the output window plus one byte
        # needed to prove overflow is retained; the rest is counted.
        # THE `io:` SEAM: the port's text
        # scans as bytes through the same loop under the identical
        # ceilings — the file on disk, or an IO handed in.
        class WindowScanner
          CHUNK_BYTES = 16 * 1024
          MAX_LINES = Truncation::DEFAULT_MAX_LINES
          MAX_BYTES = Truncation::DEFAULT_MAX_BYTES

          def initialize(offset:, limit:, path: nil, io: nil)
            raise ArgumentError, "a scanner reads a path or an io" if path.nil? == io.nil?

            @path = path
            @io = io
            @offset = offset
            @limit = limit
            @line_number = 1
            @total_file_lines = 0
            @window_lines = 0
            @window_bytes = 0
            @kept_lines = []
            @kept_bytes = 0
            @truncated_by = nil
            @first_line_exceeds_limit = false
            @first_line_bytes = 0
            reset_current_line
          end

          def call
            saw_piece = false
            last_piece_ended_line = false
            each_piece do |piece|
              ExecutionContext.current&.raise_if_cancelled!
              saw_piece = true
              last_piece_ended_line = piece.getbyte(-1) == 10
              consume(piece, ended: last_piece_ended_line)
              finish_line if last_piece_ended_line
            end
            finish_line unless saw_piece && last_piece_ended_line

            ScanResult.new(
              truncation: truncation_result,
              total_file_lines: @total_file_lines,
              first_line_bytes: @first_line_bytes
            )
          end

          private

          def each_piece(&)
            return pieces_of(@io, &) if @io

            File.open(@path, "rb") { |file| pieces_of(file, &) }
          end

          def pieces_of(io)
            while (piece = io.gets("\n", CHUNK_BYTES))
              yield piece
            end
          end

          def consume(piece, ended:)
            payload_size = piece.bytesize - (ended ? 1 : 0)
            @current_bytes += payload_size
            room = capture_limit - @current_prefix.bytesize
            return unless room.positive? && payload_size.positive?

            @current_prefix << piece.byteslice(0, [payload_size, room].min)
          end

          def finish_line
            @total_file_lines += 1
            retain_current_line if selected_line?
            @line_number += 1
            reset_current_line
          end

          def selected_line?
            return false if @line_number < @offset

            @limit.nil? || @line_number < @offset + @limit
          end

          def retain_current_line
            @window_lines += 1
            @window_bytes += 1 if @window_lines > 1
            @window_bytes += @current_bytes
            @first_line_bytes = @current_bytes if @window_lines == 1
            return unless @truncated_by.nil?

            if @kept_lines.size >= MAX_LINES
              @truncated_by = :lines
              return
            end

            fully_captured = @current_prefix.bytesize == @current_bytes
            line = @current_prefix.dup.force_encoding(Encoding::UTF_8).scrub
            @first_line_bytes = line.bytesize if @window_lines == 1 && fully_captured
            if @window_lines == 1 && (!fully_captured || line.bytesize > MAX_BYTES)
              @first_line_exceeds_limit = true
              @truncated_by = :bytes
              return
            end

            cost = line.bytesize + (@kept_lines.empty? ? 0 : 1)
            if !fully_captured || @kept_bytes + cost > MAX_BYTES
              @truncated_by = :bytes
              return
            end

            @kept_lines << line
            @kept_bytes += cost
          end

          def capture_limit
            return 0 unless selected_line? && @truncated_by.nil?
            return 0 if @kept_lines.size >= MAX_LINES

            separator = @kept_lines.empty? ? 0 : 1
            remaining = [MAX_BYTES - @kept_bytes - separator, 0].max
            remaining + 1
          end

          def reset_current_line
            @current_bytes = 0
            @current_prefix = +"".b
          end

          def truncation_result
            content = @kept_lines.join("\n").freeze
            Truncation::Result.new(
              content:,
              truncated: !@truncated_by.nil?,
              truncated_by: @truncated_by,
              total_lines: @window_lines,
              total_bytes: @window_bytes,
              output_lines: @kept_lines.size,
              output_bytes: content.bytesize,
              last_line_partial: false,
              first_line_exceeds_limit: @first_line_exceeds_limit,
              max_lines: MAX_LINES,
              max_bytes: MAX_BYTES
            )
          end
        end
        private_constant :ScanResult, :WindowScanner

        IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .webp .bmp].freeze

        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "path" => { "type" => "string", "description" => "Path to the file to read" },
            "offset" => { "type" => "integer", "description" => "1-indexed line number to start reading from" },
            "limit" => { "type" => "integer", "minimum" => 1, "description" => "Maximum number of lines to read" },
          },
          "required" => ["path"],
        })

        DESCRIPTION =
          "Read a text file or attach an image or PDF. Text output is truncated to " \
          "#{Truncation::DEFAULT_MAX_LINES} lines or #{Truncation.format_size(Truncation::DEFAULT_MAX_BYTES)} " \
          "(whichever is hit first). Use offset/limit for large text files. When you need the full text, " \
          "continue with offset until complete. Images and PDFs are attached whole; if the model cannot read " \
          "a PDF natively, use bash and the workspace tools to extract its contents.".freeze

        PROMPT_SNIPPET = "Read file contents".freeze
        PROMPT_GUIDELINES = Ractor.make_shareable(["Use read to examine files instead of cat or sed."])

        def initialize(env:)
          @env = env
        end

        # THE PORT BRANCH comes first,
        # after the chain admitted the call: a routed path — inside the
        # root set, `read` advertised — is read from the editor's buffer as
        # a WINDOW, never whole; an image or PDF is decided on the resolved path
        # before the port and stays on disk. The port's answer is a Result,
        # or the disk: with no notice for `not_found` (the editor holds
        # nothing for it), with one notice line opening the result when
        # the port was `Unavailable`.
        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          # pi clamps a non-positive offset to line 1 (read.ts Math.max);
          # the types and the positive limit are the schema's.
          offset = [args.fetch("offset", 1), 1].max
          limit = args["limit"]
          resolved = @env.resolve(args.fetch("path"))
          notice = nil
          port = capture_kind(resolved) ? nil : FsPort.routed(@env, resolved, :read)
          if port
            answer = through_port(port, resolved, offset, limit, display_path: args.fetch("path"))
            return answer if answer in Result

            notice = answer
          end

          result = from_disk(resolved, offset, limit, display_path: args.fetch("path"))
          notice ? result.with(content: "#{notice}\n\n#{result.content}") : result
        rescue Errno::EACCES
          Result.error("Permission denied: #{args["path"]}")
        end

        private

        def capture_kind(path)
          extension = File.extname(path).downcase
          if IMAGE_EXTENSIONS.include?(extension)
            "image"
          elsif extension == ".pdf"
            "PDF"
          end
        end

        def from_disk(resolved, offset, limit, display_path:)
          path = resolve_readable_path(resolved)
          return Result.error("File not found: #{resolved}") if path.nil?
          return Result.error("Not a file: #{path}") unless File.file?(path)
          kind = capture_kind(path)
          return Result.ok("#{File.basename(path)}: #{kind} attached", files: [path]) if kind

          scan = WindowScanner.new(path:, offset:, limit:).call
          if offset > scan.total_file_lines
            return Result.error(
              "Offset #{offset} is beyond end of file (#{scan.total_file_lines} lines total)"
            )
          end

          render(scan.truncation, offset, limit, total_file_lines: scan.total_file_lines,
                 first_line_bytes: scan.first_line_bytes, display_path: display_path)
        end

        # THE WINDOWED READ: `{path, line: offset, limit: (limit || MAX_LINES)
        # + 1}` — a limit always sent, one line past the window to learn
        # whether more remain, a buffer never crossing whole — scanned from
        # line 1 under the identical ceilings and footed without a total.
        # `beyond_eof`, or `""` past line 1 (harbor's shape), is rho's
        # beyond-EOF error; the client's refusal names the client. Answers
        # a Result; nil for `not_found` (the disk, no notice); the notice
        # line for `Unavailable` (the disk, the port already dropped).
        def through_port(port, resolved, offset, limit, display_path:)
          window = limit || WindowScanner::MAX_LINES
          content = FsPort.ask(port) { port.read_text(resolved, line: offset, limit: window + 1) }
          return beyond_eof(offset) if content.empty? && offset > 1

          scan = WindowScanner.new(io: StringIO.new(content.b), offset: 1, limit: window).call
          render(scan.truncation, offset, window, total_file_lines: nil,
                 first_line_bytes: scan.first_line_bytes, display_path: display_path,
                 more: scan.total_file_lines > window)
        rescue FsPort::NotFound
          nil
        rescue FsPort::BeyondEof
          beyond_eof(offset)
        rescue FsPort::Refused => error
          Result.error("#{port.client}: #{error.message}")
        rescue FsPort::Unavailable => error
          "[#{port.client} did not answer the read (#{error.message}); read from disk.]"
        end

        def beyond_eof(offset) = Result.error("Offset #{offset} is beyond end of file")

        # Exact path first, then the NFD variant — macOS file names created
        # through Finder may be NFD while models emit NFC (pi path-utils
        # subset; the AM/PM and curly-quote variants are not ported).
        def resolve_readable_path(path)
          return path if File.exist?(path)

          variant = path.unicode_normalize(:nfd)
          return variant if variant != path && File.exist?(variant)

          nil
        end

        # `total_file_lines` nil is the PORT'S shape: no total is known, and
        # `more` says whether lines remain past the window.
        def render(truncation, offset, limit, total_file_lines:, first_line_bytes:, display_path:, more: false)
          if truncation.first_line_exceeds_limit
            line_number = offset
            size = Truncation.format_size(first_line_bytes)
            return Result.ok(
              "[Line #{line_number} is #{size}, exceeds " \
              "#{Truncation.format_size(truncation.max_bytes)} limit. Use bash: " \
              "sed -n '#{line_number}p' -- #{Shellwords.shellescape(display_path)} | head -c #{truncation.max_bytes}]",
              truncation_details(truncation)
            )
          end

          shown = "#{offset}-#{offset + truncation.output_lines - 1}"
          footer =
            if total_file_lines.nil?
              port_footer(truncation, shown, offset, more)
            else
              disk_footer(truncation, shown, offset, limit, total_file_lines)
            end

          details = truncation.truncated ? truncation_details(truncation) : nil
          Result.ok("#{truncation.content}#{footer}", details)
        end

        def disk_footer(truncation, shown, offset, limit, total_file_lines)
          shown_last = offset + truncation.output_lines - 1
          next_offset = shown_last + 1
          if truncation.truncated_by == :lines
            "\n\n[Showing lines #{shown} of #{total_file_lines}. Use offset=#{next_offset} to continue.]"
          elsif truncation.truncated_by == :bytes
            "\n\n[Showing lines #{shown} of #{total_file_lines} " \
            "(#{Truncation.format_size(truncation.max_bytes)} limit). Use offset=#{next_offset} to continue.]"
          elsif limit && shown_last < total_file_lines
            "\n\n[#{total_file_lines - shown_last} more lines in file. Use offset=#{next_offset} to continue.]"
          end
        end

        # No total: the port answered one window, and whether lines remain
        # is what the extra line said or what a ceiling cut.
        def port_footer(truncation, shown, offset, more)
          return nil unless more || truncation.truncated

          next_offset = offset + truncation.output_lines
          limit = truncation.truncated_by == :bytes ? " (#{Truncation.format_size(truncation.max_bytes)} limit)" : ""
          "\n\n[Showing lines #{shown}#{limit}; more lines remain. Use offset=#{next_offset} to continue.]"
        end

        def truncation_details(truncation)
          { "truncation" => truncation.to_h.transform_keys(&:to_s) }
        end
      end
    end
  end
end
