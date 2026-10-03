require "json"
require "pathname"

module Rho
  class Runner
    module Tools
      # Ported from pi's find.ts: glob file search backed by the system fd
      # binary. Walks the search path's ancestors for a .git marker to decide
      # --no-require-git — outside a repo fd would otherwise skip .gitignore;
      # inside one, fd's git-aware defaults stop parent rules at nested repo
      # boundaries (pi issue #5960). Deviation from pi: no auto-download of a
      # missing fd — that is an operator-facing error result instead.
      #
      # WHY THE NAME IS `find`: pi's word. The
      # two references that carry this tool spell it `glob` (claude-code,
      # opencode) and our own snippet says "by glob pattern" — the name and
      # its sentence disagree. A tool's NAME is model-facing and load-
      # bearing (one parameter rename moved valid-first from 2/10 to 7/10 across ten models), so it is never re-worded by hand:
      # the glob-vs-find cell is the paid window's bench, which decides;
      # until then the word every recorded run was measured under stays.
      class Find
        NAME = "find"
        # Pure filesystem read.
        EFFECT_PROFILE = {
          "kind" => "read_only", "destructive" => false, "world" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        }.freeze

        DEFAULT_LIMIT = 1000
        MAX_LIMIT = DEFAULT_LIMIT

        # fd's --max-results already bounds the record count, so the shared
        # head truncation runs bytes-only via an unreachable line cap.
        BYTES_ONLY_MAX_LINES = 2**31

        FD_BINARIES = %w[fd fdfind].freeze

        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "pattern" => {
              "type" => "string",
              "description" => "Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'",
            },
            "path" => { "type" => "string", "description" => "Directory to search in (default: current directory)" },
            "limit" => {
              "type" => "integer",
              "minimum" => 1,
              "maximum" => MAX_LIMIT,
              "description" => "Maximum number of results (default: 1000)",
            },
          },
          "required" => ["pattern"],
        })

        DESCRIPTION =
          "Search for files by glob pattern. Returns matching file paths relative to the search directory. " \
          "Respects .gitignore. Output is truncated to #{DEFAULT_LIMIT} results or " \
          "#{Truncation::DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first).".freeze

        PROMPT_SNIPPET = "Find files by glob pattern (respects .gitignore)".freeze
        PROMPT_GUIDELINES = [].freeze

        def initialize(env:)
          @env = env
        end

        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          pattern = args.fetch("pattern")
          search_path = @env.resolve(presence(args["path"]) || ".")
          limit = args.fetch("limit", DEFAULT_LIMIT)

          fd = fd_binary
          if fd.nil?
            return Result.error(
              "fd not found on PATH (looked for #{FD_BINARIES.join(", ")}). The find tool requires fd; " \
              "install it (e.g. brew install fd, or apt install fd-find) and retry."
            )
          end

          search = run_fd(fd, pattern, search_path, limit)
          return search if search.is_a?(Result)

          # NAMES WHERE IT LOOKED, for the same reason ls does: "no files"
          # and "no files, because I searched somewhere else" read alike.
          return Result.ok("No files found matching pattern under #{search_path}") if
            search.path_count.zero?

          render(search, limit)
        end

        private

        # JS-falsy port of pi's `searchDir || "."` (empty string means unset).
        def presence(value)
          value.nil? || value.empty? ? nil : value
        end

        def fd_binary
          dirs = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject(&:empty?)
          FD_BINARIES.each do |name|
            dirs.each do |dir|
              candidate = File.join(dir, name)
              return candidate if File.file?(candidate) && File.executable?(candidate)
            end
          end
          nil
        end

        def fd_args(pattern, search_path, limit)
          args = ["--glob", "--color=never", "--hidden", "--print0"]
          args << "--no-require-git" unless inside_git_repo?(search_path)
          args << "--max-results" << limit.to_s

          # fd --glob matches basenames unless --full-path is set; in
          # --full-path mode it matches the absolute candidate path, so a
          # path-containing pattern like 'src/**/*.spec.ts' needs a leading
          # '**/' to match anything.
          effective_pattern = pattern
          if pattern.include?("/")
            args << "--full-path"
            unless pattern.start_with?("/", "**/") || pattern == "**"
              effective_pattern = "**/#{pattern}"
            end
          end

          args + ["--", effective_pattern, search_path]
        end

        def run_fd(fd, pattern, search_path, limit)
          child = Subprocess.start(fd, *fd_args(pattern, search_path, limit))
          begin
            ExecutionContext.with_cancel_signal(-> { child.cancel }) do
              child.stdin.close

              search = collect_paths(child, search_path, limit)
              return search if search.is_a?(Result)

              status = child.wait
              stderr_text = child.stderr_text
              unless search.limit_reached || status.success? || search.path_count.positive?
                message = stderr_text.strip
                return Result.error(message.empty? ? "fd exited with code #{status.exitstatus}" : message)
              end

              search
            end
          ensure
            child.cleanup
          end
        end

        def collect_paths(child, search_path, limit)
          paths = []
          display_paths = []
          path_count = 0
          total_bytes = 0
          output_bytes = 0
          truncated_by = nil
          first_line_exceeds_limit = false

          each_fd_record(child.stdout) do |record|
            if record.truncated
              return Result.error("fd output record exceeded #{Subprocess::MAX_STDOUT_LINE_BYTES} bytes")
            end

            path = relativize_record(record.content, search_path)
            next unless path

            display = display_path(path)
            path_count += 1
            total_bytes += display.bytesize + (path_count == 1 ? 0 : 1)
            if truncated_by.nil?
              cost = display.bytesize + (paths.empty? ? 0 : 1)
              if output_bytes + cost <= Truncation::DEFAULT_MAX_BYTES
                paths << path
                display_paths << display
                output_bytes += cost
              else
                truncated_by = :bytes
                first_line_exceeds_limit = paths.empty?
              end
            end
          end

          Search.new(
            paths:,
            path_count:,
            limit_reached: path_count >= limit,
            truncation: Truncation::Result.new(
              content: display_paths.join("\n").freeze,
              truncated: !truncated_by.nil?,
              truncated_by:,
              total_lines: path_count,
              total_bytes:,
              output_lines: paths.size,
              output_bytes:,
              last_line_partial: false,
              first_line_exceeds_limit:,
              max_lines: BYTES_ONLY_MAX_LINES,
              max_bytes: Truncation::DEFAULT_MAX_BYTES
            )
          )
        end

        # fd's NUL mode is the only unambiguous record boundary for POSIX
        # paths: newlines and trailing whitespace are legal filename bytes.
        # IO#gets' limit keeps one malicious record bounded without buffering
        # the rest of it; a valid max-sized record may use one extra byte for
        # its terminating NUL.
        def each_fd_record(io)
          return enum_for(__method__, io) unless block_given?

          max_bytes = Subprocess::MAX_STDOUT_LINE_BYTES
          io.binmode
          while (raw_record = io.gets("\0", max_bytes + 1))
            ExecutionContext.current&.raise_if_cancelled!
            terminated = raw_record.end_with?("\0")
            truncated = !terminated && raw_record.bytesize > max_bytes
            content = terminated ? raw_record.byteslice(0, raw_record.bytesize - 1) : raw_record
            content = content.dup.force_encoding(Encoding::UTF_8).scrub.freeze
            yield Subprocess::OutputLine.new(content:, truncated:)
          end
        end

        def inside_git_repo?(dir)
          current = dir
          loop do
            return true if File.exist?(File.join(current, ".git"))

            parent = File.dirname(current)
            return false if parent == current

            current = parent
          end
        end

        # Relativizes one fd record against the search dir, preserving fd's
        # trailing "/" on directories.
        def relativize_record(record, search_path)
          return if record.empty?

          had_trailing_slash = record.end_with?("/", "\\")
          prefix = search_path.end_with?("/") ? search_path : "#{search_path}/"
          relative =
            if record.start_with?(prefix)
              record.delete_prefix(prefix)
            else
              Pathname.new(record).relative_path_from(Pathname.new(search_path)).to_s
            end
          relative += "/" if had_trailing_slash && !relative.end_with?("/")
          relative
        end

        # The model-facing result remains one line per record even when a
        # legal POSIX filename contains a newline or another control byte.
        # JSON string escaping is reversible and also distinguishes a literal
        # backslash-n from an embedded newline; exact raw paths ride structured
        # content when any record needed escaping.
        def display_path(path)
          encoded = JSON.generate(path)
          encoded.byteslice(1, encoded.bytesize - 2)
        end

        Search = Data.define(:paths, :path_count, :limit_reached, :truncation)

        def render(search, limit)
          truncation = search.truncation

          notices = []
          details = {}
          details["paths"] = search.paths if search.paths.any? { |path| display_path(path) != path }
          if search.limit_reached
            next_limit = [limit * 2, MAX_LIMIT].min
            suggestion =
              if next_limit > limit
                "Use limit=#{next_limit} for more, or refine pattern"
              else
                "Refine pattern or path to reduce results"
              end
            notices << "#{limit} results limit reached. #{suggestion}"
            details["result_limit_reached"] = true
          end
          if truncation.truncated
            notices << "#{Truncation.format_size(truncation.max_bytes)} limit reached"
            details["truncation"] = truncation.to_h.transform_keys(&:to_s)
          end

          output = truncation.content
          output += "\n\n[#{notices.join(". ")}]" if notices.any?
          Result.ok(output, details.empty? ? nil : details)
        end
      end
    end
  end
end
