require "fileutils"
require "json"

module E2E
  module Evals
    # One local JSON line per (task, model, style, run) under
    # `artifacts/evals/runs/<date>-<label>/records.jsonl`, appended as each run ends so a lane that dies
    # mid-invocation leaves what it finished. Read back MERGED: a later line on the same key
    # replaces the earlier one (`TaskBench::Report.merge_live`'s shape — the newer record wins), so
    # a re-run of one cell overwrites nothing on disk and still reads as one row. The full trace
    # goes to the artifact the record points at. Both records and traces stay untracked.
    module Records
      FILE = "records.jsonl".freeze
      KEY = %w[task model style run].freeze

      module_function

      def path(run_dir) = File.join(run_dir, FILE)

      def key(record) = record.values_at(*KEY)

      # ONE LABEL IS ONE BENCH: the ledger files a label under one digest and the scorecard reads it
      # as one column, so a record run under another bench is refused here, where every writer (the
      # lane, a harbor import, a re-score) appends, before a mixed file can exist.
      def append(run_dir, record)
        refuse_mixed_digests!(run_dir, read(run_dir) + [record])
        FileUtils.mkdir_p(run_dir)
        File.open(path(run_dir), "a", encoding: Encoding::UTF_8) { |file| file.puts(JSON.generate(record)) }
        record
      end

      # The one refusal, shared with the scorecard's reader for a file written some other way.
      def refuse_mixed_digests!(run_dir, rows)
        digests = rows.map { |row| row["bench_digest"] }.uniq
        raise ArgumentError, "#{path(run_dir)} mixes bench digests #{digests.inspect}: split the label" if digests.size > 1
      end

      # A line that will not parse is a diagnostic, not a crash: the file is
      # appended by a lane that may have died mid-line.
      def read(run_dir)
        file = path(run_dir)
        return [] unless File.file?(file)

        rows = File.readlines(file, encoding: Encoding::UTF_8, chomp: true).reject(&:empty?).filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          warn "records: an unparseable line in #{file} was skipped"
          nil
        end
        merge([], rows)
      end

      # `to_h` keeps the LAST row for a repeated key: the newer wins.
      def merge(older, newer) = (older + newer).to_h { |row| [key(row), row] }.values

      # A compacted rewrite: the merged rows, one line each.
      def write(run_dir, records)
        FileUtils.mkdir_p(run_dir)
        File.write(path(run_dir), records.map { |row| JSON.generate(row) }.join("\n").then { |text| text.empty? ? "" : "#{text}\n" })
      end

      # Every label under the runs dir with a ledger, oldest first (the
      # directory names are dated), as `label => merged records`.
      def read_all(runs_dir)
        return {} unless File.directory?(runs_dir)

        Dir.children(runs_dir).sort.select { |label| File.file?(path(File.join(runs_dir, label))) }
          .to_h { |label| [label, read(File.join(runs_dir, label))] }
      end
    end
  end
end
