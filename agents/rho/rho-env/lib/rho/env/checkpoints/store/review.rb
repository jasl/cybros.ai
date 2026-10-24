require_relative "../review"

module Rho
  module Env
    module Checkpoints
      class Store
        # Freeze the cumulative change at tool return, while the exact bytes
        # are in this store. History never rereads the user's work tree.
        def review(run_public_id:)
          operation do |deadline|
            baseline = read_record(loop_name(run_public_id), 0)
            next nil unless baseline

            target = manifest(baseline.hash)
            previous = working
            scan = scan_tree(previous, deadline)
            next Skip.new(reason: "tree_too_large", bytes: scan.bytes, files: scan.files) if scan.bytes > @max_tree_bytes

            entries = transaction do
              current = materialize(scan, previous, deadline)
              save_working(current)
              current
            end
            rows = differences(target, entries)
            Review.new(root: @root, base: baseline.hash, rows: rows, deadline: deadline, git: @git_binary, clock: @clock).document do |path|
              old = target[path]
              current = entries[path]
              [review_bytes(old), review_bytes(current), old&.mode, current&.mode]
            end
          end
        rescue TimedOut, Git::TimedOut
          Skip.new(reason: "timeout")
        rescue Failed, Git::Failed, SystemCallError, IOError => error
          skip(error)
        end

        private

          def review_bytes(entry)
            return nil unless entry
            return entry.hash if entry.mode == GITLINK

            bytes, compressed = @db.get_first_row("SELECT data, compressed FROM blobs WHERE hash = ?", [entry.hash])
            compressed == 1 ? Zlib::Inflate.inflate(bytes) : bytes
          end
      end
    end
  end
end
