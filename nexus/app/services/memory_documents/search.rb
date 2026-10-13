module MemoryDocuments
  # Grep, not search: this store cannot rank, and a model that gets
  # nothing from two natural-language queries stops calling it. The match
  # runs in Ruby under a timeout — Postgres `~` is not linear on a hostile pattern.
  class Search
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 500
    MATCH_TIMEOUT_SECONDS = 1.0
    # Long lines are the common shape in a notes file, and an unbounded
    # one would put a whole document into a result that promised a line.
    MAX_LINE_LENGTH = 500

    Match = Data.define(:path, :line_number, :text)
    Result = Data.define(:matches, :truncated, :refusal) do
      def found? = refusal.nil?
    end

    class << self
      def call(documents:, pattern:, ignore_case: false, limit: nil, path_prefix: nil, paths: nil)
        matcher = compile(pattern, ignore_case)
        return Result.new(matches: [], truncated: false, refusal: :memory_pattern_invalid) if
          matcher.nil?

        bound = (Integer(limit || DEFAULT_LIMIT, exception: false) || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
        scan(documents, matcher, bound, path_prefix, paths)
      rescue Regexp::TimeoutError
        Result.new(matches: [], truncated: false, refusal: :memory_pattern_too_costly)
      end

      private

        def compile(pattern, ignore_case)
          text = String.try_convert(pattern)
          return nil if text.nil? || text.empty?

          Regexp.new(text, ignore_case ? Regexp::IGNORECASE : 0,
            timeout: MATCH_TIMEOUT_SECONDS)
        rescue RegexpError
          nil
        end

        # Ordered by path then line, never by a score, because there is no
        # score — a stable order is the only honest thing an unranked
        # store can promise.
        def scan(documents, matcher, bound, path_prefix, paths)
          matches = []
          truncated = false
          rows(documents, path_prefix, paths).each do |path, document|
            document.content.each_line.with_index(1) do |line, number|
              next unless matcher.match?(line)

              if matches.length >= bound
                truncated = true
                break
              end
              matches << Match.new(path: path, line_number: number,
                text: clamp(line.chomp))
            end
            break if truncated
          end
          Result.new(matches: matches, truncated: truncated, refusal: nil)
        end

        # Path order, like the listing: scope-grouped across a union.
        def rows(documents, path_prefix, paths)
          scoped = documents.includes(:memory_document_version)
          unless path_prefix.blank?
            scoped = scoped.where("name LIKE ?",
              "#{ActiveRecord::Base.sanitize_sql_like(path_prefix)}%")
          end
          scoped.flat_map do |document|
            (paths ? paths.call(document) : [document.path]).map { |path| [path, document] }
          end.sort_by(&:first)
        end

        def clamp(text)
          return text if text.length <= MAX_LINE_LENGTH

          "#{text[0, MAX_LINE_LENGTH]}…"
        end
    end
  end
end
