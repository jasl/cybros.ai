module Rho
  class Runner
    module Tools
      # Ported from pi's ls.ts: case-insensitive alphabetical directory
      # listing with a "/" suffix on directories and dotfiles included.
      # The entry cap (limit) is applied first, then the shared byte cap —
      # max_lines is effectively unbounded because the entry cap already
      # bounds line count (one entry per line).
      #
      # WHY THE SEVENTH TOOL STAYS: codex,
      # claude-code and opencode offer the model no `ls`, but ours is
      # model-CHOSEN — the 2026-09-11 scorecards show kimi-k3, glm-5.3,
      # glm-5.3-flash and deepseek-v4.1-flash each opening a lane with one
      # `ls` call before `read`/`bash`, and exit-medium's REACH row counts
      # it beside `read`/`grep`/`find`. It is also the one listing that
      # never ASKS: rho's `READ_ONLY_TOOLS` allow rule names it, where
      # `bash ls` is a `bash` call judged by the bash rules (a park on a
      # read). The drop-it-for-`find` cell is the paid window's bench,
      # which decides; the cleanup records, never hand-words.
      class Ls
        NAME = "ls"
        # Pure filesystem read.
        EFFECT_PROFILE = {
          "kind" => "read_only", "destructive" => false, "world" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        }.freeze

        DEFAULT_LIMIT = 500
        SORT_CANCELLATION_INTERVAL = 128
        private_constant :SORT_CANCELLATION_INTERVAL

        # pi passes Number.MAX_SAFE_INTEGER so truncate_head is bytes-only.
        UNBOUNDED_LINES = (2**53) - 1

        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "path" => { "type" => "string", "description" => "Directory to list (default: current directory)" },
            "limit" => {
              "type" => "integer",
              "minimum" => 1,
              "description" => "Maximum number of entries to return (default: 500)",
            },
          },
          "required" => [],
        })

        DESCRIPTION =
          "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. " \
          "Includes dotfiles. Output is truncated to #{DEFAULT_LIMIT} entries or " \
          "#{Truncation::DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first).".freeze

        PROMPT_SNIPPET = "List directory contents".freeze
        PROMPT_GUIDELINES = [].freeze

        def initialize(env:)
          @env = env
        end

        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          dir = @env.resolve(args["path"] || ".")
          limit = args.fetch("limit", DEFAULT_LIMIT)

          return Result.error("Path not found: #{dir}") unless File.exist?(dir)
          return Result.error("Not a directory: #{dir}") unless File.directory?(dir)

          begin
            entries = directory_entries(dir)
          rescue SystemCallError => e
            return Result.error("Cannot read directory: #{e.message}")
          end

          results, entry_limit_reached = format_entries(dir, sort_entries(entries), limit)
          # NAMES WHERE IT LOOKED. An empty listing and a listing of the
          # wrong directory are the same four words otherwise, and a
          # relative path resolves against the runner's root rather than
          # wherever the caller imagines it stands.
          return Result.ok("(empty directory: #{dir})") if results.empty?

          render(results, limit, entry_limit_reached)
        end

        private

        def directory_entries(dir)
          entries = []
          Dir.each_child(dir) do |entry|
            ExecutionContext.current&.raise_if_cancelled!
            entries << entry
          end
          entries
        end

        # Decorate/sort!/undecorate exists solely to put a bounded cancellation
        # checkpoint inside the comparator (sort_by exposes no comparison
        # seam); the surrounding maps are trivial per element and carry no
        # checks — enumeration and formatting bound their own latency.
        def sort_entries(entries)
          context = ExecutionContext.current
          return entries.sort_by(&:downcase) unless context

          decorated = entries.map { |entry| [entry.downcase, entry] }
          comparisons = 0
          decorated.sort! do |left, right|
            comparisons += 1
            context.raise_if_cancelled! if (comparisons % SORT_CANCELLATION_INTERVAL).zero?
            left.first <=> right.first
          end
          decorated.map { |_key, entry| entry }
        end

        def format_entries(dir, entries, limit)
          results = []
          entry_limit_reached = false

          entries.each do |entry|
            ExecutionContext.current&.raise_if_cancelled!
            if results.size >= limit
              entry_limit_reached = true
              break
            end

            begin
              stat = File.stat(File.join(dir, entry))
            rescue SystemCallError
              next # pi shape: entries whose stat fails are silently skipped.
            end

            # stat needs the raw filesystem bytes; the RESULT must be valid
            # UTF-8 (the tool-result envelope rejects anything else, like the
            # find/grep/bash output normalization). Directory names arrive in
            # the filesystem encoding — US-ASCII under a C locale, or bytes
            # that are not valid UTF-8 — so scrub the display copy.
            display = entry.dup.force_encoding(Encoding::UTF_8).scrub
            results << (stat.directory? ? "#{display}/" : display)
          end

          [results, entry_limit_reached]
        end

        def render(results, limit, entry_limit_reached)
          truncation = Truncation.truncate_head(results.join("\n"), max_lines: UNBOUNDED_LINES)

          notices = []
          notices << "#{limit} entries limit reached. Use limit=#{limit * 2} for more" if entry_limit_reached
          notices << "#{Truncation.format_size(truncation.max_bytes)} limit reached" if truncation.truncated

          output = truncation.content
          # pi joins all applicable notices into ONE bracket with ". ".
          output += "\n\n[#{notices.join(". ")}]" if notices.any?

          Result.ok(output, details(entry_limit_reached, truncation))
        end

        def details(entry_limit_reached, truncation)
          payload = {}
          payload["entry_limit_reached"] = true if entry_limit_reached
          payload["truncation"] = truncation.to_h.transform_keys(&:to_s) if truncation.truncated
          payload.empty? ? nil : payload
        end
      end
    end
  end
end
