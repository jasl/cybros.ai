module Rho
  class Runner
    # THE OUTPUT BOUND, and it exists to defend the MODEL rather than this
    # process: a tool that returns a 40 MB file does not crash anything here,
    # it eats the round's context and costs the turn. Ported from pi's
    # truncate.ts.
    #
    # Two independent limits and whichever is hit first wins. A result never
    # contains a partial line, with one deliberate exception on the tail side:
    # when not even one line fits, the last max_bytes of the final line are
    # kept, cut at a valid UTF-8 boundary — because returning nothing at all
    # from a command whose one line was the answer is worse.
    module Truncation
      DEFAULT_MAX_LINES = 2000
      DEFAULT_MAX_BYTES = 50 * 1024
      GREP_MAX_LINE_LENGTH = 500

      Result = Data.define(
        :content,          # the (possibly truncated) output
        :truncated,        # boolean
        :truncated_by,     # :lines | :bytes | nil
        :total_lines,      # line count of the full input
        :total_bytes,      # bytesize of the full input
        :output_lines,     # line count of the kept content
        :output_bytes,     # bytesize of the kept content
        :last_line_partial,        # tail-only: the single kept line was cut
        :first_line_exceeds_limit, # head-only: line 1 alone is over max_bytes
        :max_lines,
        :max_bytes
      )

      module_function

      # One counting convention, pinned (pi's read.ts and truncate.ts disagreed
      # by one on trailing-newline files; the port picks truncate.ts and uses it
      # everywhere): a trailing newline does not open a final empty line.
      def split_lines_for_counting(content)
        return [""] if content.empty?

        lines = content.split("\n", -1)
        lines.pop if content.end_with?("\n")
        lines
      end

      # Keep the head. Used by read (full line+byte pipeline) and by
      # grep/find/ls (bytes-only via a huge max_lines).
      def truncate_head(content, max_lines: DEFAULT_MAX_LINES, max_bytes: DEFAULT_MAX_BYTES)
        lines = split_lines_for_counting(content)
        total_bytes = content.bytesize

        if lines.first && line_bytes(lines.first) > max_bytes
          return Result.new(
            content: "".freeze, truncated: true, truncated_by: :bytes,
            total_lines: lines.size, total_bytes:, output_lines: 0, output_bytes: 0,
            last_line_partial: false, first_line_exceeds_limit: true, max_lines:, max_bytes:
          )
        end

        kept = []
        kept_bytes = 0
        truncated_by = nil

        lines.each do |line|
          if kept.size >= max_lines
            truncated_by = :lines
            break
          end

          cost = line_bytes(line) + (kept.empty? ? 0 : 1)
          if kept_bytes + cost > max_bytes
            truncated_by = :bytes
            break
          end

          kept << line
          kept_bytes += cost
        end

        build_result(kept, lines, total_bytes, truncated_by, max_lines, max_bytes, last_line_partial: false)
      end

      # Keep the tail. Used by bash via the output accumulator's snapshot. If
      # not even one line fits, keeps the last max_bytes of the final line cut
      # at a valid UTF-8 boundary and marks last_line_partial.
      def truncate_tail(content, max_lines: DEFAULT_MAX_LINES, max_bytes: DEFAULT_MAX_BYTES)
        lines = split_lines_for_counting(content)
        total_bytes = content.bytesize

        kept = []
        kept_bytes = 0
        truncated_by = nil

        lines.reverse_each do |line|
          if kept.size >= max_lines
            truncated_by = :lines
            break
          end

          cost = line_bytes(line) + (kept.empty? ? 0 : 1)
          if kept_bytes + cost > max_bytes
            truncated_by = :bytes
            break
          end

          kept.unshift(line)
          kept_bytes += cost
        end

        if kept.empty? && lines.any?
          partial = tail_bytes_at_character_boundary(lines.last, max_bytes).freeze
          return Result.new(
            content: partial, truncated: true, truncated_by: :bytes,
            total_lines: lines.size, total_bytes:,
            output_lines: 1, output_bytes: partial.bytesize,
            last_line_partial: true, first_line_exceeds_limit: false, max_lines:, max_bytes:
          )
        end

        build_result(kept, lines, total_bytes, truncated_by, max_lines, max_bytes, last_line_partial: false)
      end

      def truncate_line(line, max_chars: GREP_MAX_LINE_LENGTH)
        return line if line.length <= max_chars

        "#{line[0, max_chars]}... [truncated]"
      end

      def format_size(bytes)
        if bytes < 1024
          "#{bytes}B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)}KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(1)}MB"
        end
      end

      def line_bytes(line)
        line.bytesize
      end
      private_class_method :line_bytes

      def tail_bytes_at_character_boundary(line, max_bytes)
        bytes = line.b
        start = bytes.bytesize - max_bytes
        start += 1 while start < bytes.bytesize && (bytes.getbyte(start) & 0xC0) == 0x80
        bytes.byteslice(start..).force_encoding(line.encoding)
      end
      private_class_method :tail_bytes_at_character_boundary

      def build_result(kept, lines, total_bytes, truncated_by, max_lines, max_bytes, last_line_partial:)
        content = kept.join("\n").freeze
        Result.new(
          content:, truncated: !truncated_by.nil?, truncated_by:,
          total_lines: lines.size, total_bytes:,
          output_lines: kept.size, output_bytes: content.bytesize,
          last_line_partial:, first_line_exceeds_limit: false, max_lines:, max_bytes:
        )
      end
      private_class_method :build_result
    end
  end
end
