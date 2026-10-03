require "json"
require "pathname"

module Rho
  class Runner
    module Tools
      # Ported from pi's grep.ts: ripgrep-backed content search streaming
      # rg --json match events, killed early once the match limit is hit,
      # with context blocks re-read from disk and the shared bytes-only head
      # cap. Deviation from pi: rho requires a system `rg` on PATH and never
      # auto-downloads one (pi's tools-manager is not ported).
      class Grep
        NAME = "grep"
        # Pure filesystem read.
        EFFECT_PROFILE = {
          "kind" => "read_only", "destructive" => false, "world" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        }.freeze

        DEFAULT_LIMIT = 100
        MAX_LIMIT = 500
        MAX_CONTEXT = 20

        # The byte cap is the only truncation axis here (the match limit
        # already capped rows), so the line cap is pushed out of reach —
        # pi uses Number.MAX_SAFE_INTEGER for the same purpose.
        UNLIMITED_LINES = 9_007_199_254_740_991

        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "pattern" => { "type" => "string", "description" => "Search pattern (regex or literal string)" },
            "path" => {
              "type" => "string",
              "description" => "Directory or file to search (default: current directory)",
            },
            "glob" => {
              "type" => "string",
              "description" => "Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'",
            },
            "ignoreCase" => { "type" => "boolean", "description" => "Case-insensitive search (default: false)" },
            "literal" => {
              "type" => "boolean",
              "description" => "Treat pattern as literal string instead of regex (default: false)",
            },
            "context" => {
              "type" => "integer",
              "minimum" => 0,
              "maximum" => MAX_CONTEXT,
              "description" => "Number of lines to show before and after each match (default: 0)",
            },
            "limit" => {
              "type" => "integer",
              "minimum" => 1,
              "maximum" => MAX_LIMIT,
              "description" => "Maximum number of matches to return (default: #{DEFAULT_LIMIT})",
            },
          },
          "required" => ["pattern"],
        })

        DESCRIPTION =
          "Search file contents for a pattern. Returns matching lines with file paths and line numbers. " \
          "Respects .gitignore. Output is truncated to #{DEFAULT_LIMIT} matches or " \
          "#{Truncation::DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first). " \
          "Long lines are truncated to #{Truncation::GREP_MAX_LINE_LENGTH} chars.".freeze

        PROMPT_SNIPPET = "Search file contents for patterns (respects .gitignore)".freeze
        PROMPT_GUIDELINES = [].freeze

        Match = Data.define(:file_path, :line_number, :line_text)
        Search = Data.define(:matches, :match_count, :limit_reached, :oversized_lines)

        # Reads only the requested context lines and retains enough bytes to
        # render each at grep's existing character limit.
        class ContextLineReader
          CHUNK_BYTES = 16 * 1024
          MAX_CAPTURE_BYTES = (Truncation::GREP_MAX_LINE_LENGTH + 1) * 4

          def initialize(path:, ranges:)
            @path = path
            @ranges = merge_ranges(ranges)
            @last_line = @ranges.last.last
            @range_index = 0
            @lines = {}
            @line_number = 1
            @skip_lf_after_cr = false
            reset_line
          end

          def call
            File.open(@path, "rb") do |file|
              while (chunk = file.read(CHUNK_BYTES))
                ExecutionContext.current&.raise_if_cancelled!
                chunk.each_byte do |byte|
                  consume(byte)
                  break if complete?
                end
                break if complete?
              end
            end
            finish_line unless complete?
            @lines
          end

          private

          def consume(byte)
            if @skip_lf_after_cr
              @skip_lf_after_cr = false
              return if byte == 10
            end

            case byte
            when 13
              finish_line
              @skip_lf_after_cr = true
            when 10
              finish_line
            else
              @captured << byte if selected? && @captured.bytesize < MAX_CAPTURE_BYTES
              @overflow ||= selected? && @captured.bytesize >= MAX_CAPTURE_BYTES
            end
          end

          def finish_line
            if selected?
              text = @captured.dup.force_encoding(Encoding::UTF_8).scrub
              truncated = @overflow || text.length > Truncation::GREP_MAX_LINE_LENGTH
              @lines[@line_number] = [Truncation.truncate_line(text), truncated]
            end
            @line_number += 1
            reset_line
          end

          def selected?
            advance_range
            range = @ranges[@range_index]
            range && @line_number >= range.first && @line_number <= range.last
          end

          def complete?
            @line_number > @last_line
          end

          def advance_range
            while (range = @ranges[@range_index]) && @line_number > range.last
              @range_index += 1
            end
          end

          def merge_ranges(ranges)
            ranges.sort_by(&:first).each_with_object([]) do |range, merged|
              previous = merged.last
              if previous && range.first <= previous.last + 1
                merged[-1] = previous.first..[previous.last, range.last].max
              else
                merged << range
              end
            end
          end

          def reset_line
            @captured = +"".b
            @overflow = false
          end
        end
        private_constant :ContextLineReader

        def initialize(env:)
          @env = env
        end

        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          pattern = args.fetch("pattern")
          search_path = @env.resolve(args["path"] || ".")
          return Result.error("Path not found: #{search_path}") unless File.exist?(search_path)

          # The types and both ranges are the schema's (`minimum`/`maximum`
          # above, refused before the handler by `InputSchema`).
          context = args.fetch("context", 0)
          effective_limit = args.fetch("limit", DEFAULT_LIMIT)

          search = run_ripgrep(rg_argv(args, pattern, search_path), effective_limit)
          return search if search.is_a?(Result)

          render(search, search_path, context, effective_limit)
        end

        private

        def rg_argv(args, pattern, search_path)
          argv = ["rg", "--json", "--line-number", "--color=never", "--hidden"]
          argv << "--ignore-case" if args["ignoreCase"]
          argv << "--fixed-strings" if args["literal"]
          argv.push("--glob", args["glob"]) if args["glob"]
          argv.push("--", pattern, search_path)
        end

        # Streams rg's --json events and kills the child as soon as the match
        # limit is reached (we already have everything we need). Exit codes 0
        # and 1 are both success — 1 just means no matches.
        def run_ripgrep(argv, effective_limit)
          matches = []
          match_count = 0
          limit_reached = false
          oversized_lines = 0

          child = Subprocess.start(*argv)
          begin
            ExecutionContext.with_cancel_signal(-> { child.cancel }) do
              child.stdin.close

              child.each_stdout_line do |line|
                ExecutionContext.current&.raise_if_cancelled!
                if line.truncated
                  # A single giant match line (a minified file, say) must not
                  # fail the whole search: skip that match and say so, keeping
                  # the advertised long-lines-are-truncated contract honest.
                  oversized_lines += 1
                  next
                end

                match = parse_match(line.content)
                next unless match

                match_count += 1
                matches << match unless match == :malformed
                if match_count >= effective_limit
                  limit_reached = true
                  child.kill_and_reap
                  break
                end
              end

              status = child.wait
              stderr_text = child.stderr_text
              unless limit_reached || [0, 1].include?(status.exitstatus)
                message = stderr_text.strip
                message = "ripgrep exited with code #{status.exitstatus.inspect}" if message.empty?
                return Result.error(message)
              end
            end
          ensure
            child.cleanup
          end

          Search.new(matches:, match_count:, limit_reached:, oversized_lines:)
        rescue Errno::ENOENT
          Result.error(
            "ripgrep (rg) was not found on PATH. Install ripgrep " \
            "(e.g. `brew install ripgrep` or `apt install ripgrep`) to use grep"
          )
        end

        # Returns a Match, :malformed (a match event missing path/line — still
        # counted against the limit, as in pi), or nil for non-match events.
        def parse_match(line)
          stripped = line.strip
          return nil if stripped.empty?

          event = JSON.parse(stripped)
          return nil unless event.is_a?(Hash) && event["type"] == "match"

          data = event["data"] || {}
          file_path = data.dig("path", "text")
          line_number = data["line_number"]
          return :malformed unless file_path && line_number.is_a?(Integer)

          Match.new(file_path:, line_number:, line_text: data.dig("lines", "text"))
        rescue JSON::ParserError
          nil
        end

        def render(search, search_path, context, effective_limit)
          if search.match_count.zero?
            if search.oversized_lines.positive?
              return Result.ok(
                "No matches found\n\n[#{search.oversized_lines} match(es) skipped: output line over " \
                "#{Subprocess::MAX_STDOUT_LINE_BYTES} bytes. Use read tool on the file instead]",
                { "oversized_lines_skipped" => search.oversized_lines }
              )
            end

            return Result.ok("No matches found in #{search_path}")
          end

          output_lines, lines_truncated = format_matches(search.matches, search_path, context)
          truncation = Truncation.truncate_head(output_lines.join("\n"), max_lines: UNLIMITED_LINES)

          details = {}
          notices = []
          if search.limit_reached
            next_limit = [effective_limit * 2, MAX_LIMIT].min
            suggestion =
              if next_limit > effective_limit
                "Use limit=#{next_limit} for more, or refine pattern"
              else
                "Refine pattern to reduce matches"
              end
            notices << "#{effective_limit} matches limit reached. #{suggestion}"
            details["match_limit_reached"] = true
          end
          if truncation.truncated
            notices << "#{Truncation.format_size(Truncation::DEFAULT_MAX_BYTES)} limit reached"
            details["truncation"] = truncation.to_h.transform_keys(&:to_s)
          end
          if lines_truncated
            notices << "Some lines truncated to #{Truncation::GREP_MAX_LINE_LENGTH} chars. " \
                       "Use read tool to see full lines"
            details["lines_truncated"] = true
          end
          if search.oversized_lines.positive?
            notices << "#{search.oversized_lines} match(es) skipped: output line over " \
                       "#{Subprocess::MAX_STDOUT_LINE_BYTES} bytes. Use read tool on the file instead"
            details["oversized_lines_skipped"] = search.oversized_lines
          end

          output = truncation.content
          output = "#{output}\n\n[#{notices.join(". ")}]" if notices.any?
          Result.ok(output, details.empty? ? nil : details)
        end

        # Consecutive blocks are concatenated with plain newlines — no
        # separator rows between blocks (pi grep.ts:317-331).
        def format_matches(matches, search_path, context)
          directory = File.directory?(search_path)
          context_lines = read_context_lines(matches, context)
          lines_truncated = false
          output_lines = []

          matches.each do |match|
            ExecutionContext.current&.raise_if_cancelled!
            display = display_path(match.file_path, search_path, directory)
            if context.zero? && match.line_text
              text, cut = capped_line(sanitize_match_text(match.line_text))
              output_lines << "#{display}:#{match.line_number}: #{text}"
            else
              block, cut = format_block(display, match.line_number, context, context_lines[match.file_path])
              output_lines.concat(block)
            end
            lines_truncated ||= cut
          end

          [output_lines, lines_truncated]
        end

        # A block around one match: the match line uses ":" separators,
        # context lines use "-" separators.
        def format_block(display, line_number, context, lines)
          first = context.positive? ? [1, line_number - context].max : line_number
          last = context.positive? ? line_number + context : line_number
          return [["#{display}:#{line_number}: (unable to read file)"], false] if lines.empty? || !lines.key?(line_number)

          cut_any = false
          block = (first..last).filter_map do |current|
            text, cut = lines[current]
            next unless text

            cut_any ||= cut
            separator = current == line_number ? ":" : "-"
            "#{display}#{separator}#{current}#{separator} #{text}"
          end
          [block, cut_any]
        end

        def read_context_lines(matches, context)
          ranges_by_file = Hash.new { |hash, path| hash[path] = [] }
          matches.each do |match|
            ExecutionContext.current&.raise_if_cancelled!
            next unless context.positive? || match.line_text.nil?

            first = context.positive? ? [1, match.line_number - context].max : match.line_number
            last = context.positive? ? match.line_number + context : match.line_number
            ranges_by_file[match.file_path] << (first..last)
          end

          ranges_by_file.each_with_object({}) do |(file_path, ranges), lines_by_file|
            lines_by_file[file_path] = ContextLineReader.new(path: file_path, ranges:).call
          rescue StandardError
            lines_by_file[file_path] = {}
          end
        end

        # Relative to the search dir when searching a directory, basename when
        # searching a single file (or when the path falls outside the dir).
        def display_path(file_path, search_path, directory)
          if directory
            relative = relative_to(file_path, search_path)
            return relative if relative && relative != "." && !relative.start_with?("..")
          end
          File.basename(file_path)
        end

        def relative_to(file_path, search_path)
          Pathname.new(file_path).relative_path_from(Pathname.new(search_path)).to_s
        rescue ArgumentError
          nil
        end

        def sanitize_match_text(text)
          text.gsub("\r\n", "\n").delete("\r").sub(/\n\z/, "")
        end

        def capped_line(line)
          [Truncation.truncate_line(line), line.length > Truncation::GREP_MAX_LINE_LENGTH]
        end
      end
    end
  end
end
