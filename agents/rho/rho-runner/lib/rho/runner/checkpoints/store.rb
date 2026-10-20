require "sqlite3"
require "digest"
require "find"
require "json"
require "fileutils"
require "tempfile"
require "time"
require "zlib"

module Rho
  class Runner
    module Checkpoints
      # One SQLite database per real work root. Content, complete manifests,
      # create-only capture/undo records and the working stat index commit
      # together. The root mutex/flock spans undo publication and file restore.
      # Source files and whole-tree restoration are not an atomic filesystem
      # snapshot: a cancelled restore keeps its committed, discoverable undo.
      class Store
        DIRECTORY = "checkpoints".freeze
        DATABASE_FILE = "checkpoints.sqlite3".freeze
        DEFAULT_MAX_FILE_BYTES = 2 * 1024 * 1024
        DEFAULT_MAX_TREE_BYTES = 256 * 1024 * 1024
        DEFAULT_CAPTURE_TIMEOUT_SECONDS = 30
        DEFAULT_RETENTION_DAYS = 7
        OPEN_TIMEOUT_SECONDS = 60
        PRUNE_TIMEOUT_FACTOR = 10
        GITLINK = "160000".freeze
        LOOP_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
        STORE_ID = /\A[0-9a-f]{16}\z/
        LOCK_FILE = "lock".freeze

        class TimedOut < Error; end
        class Failed < Error; end

        Entry = Data.define(:mode, :hash, :stat, :verified_at) do
          def self.parse(value) = new(**value.transform_keys(&:to_sym))
          def initialize(mode:, hash:, stat:, verified_at: 0) = super
          def content = [mode, hash]
        end
        Scan = Data.define(:entries, :skipped, :files, :bytes)
        private_constant :Entry, :Scan

        CHUNK = 256 * 1024
        SCHEMA = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS blobs (
            hash TEXT PRIMARY KEY, data BLOB NOT NULL, compressed INTEGER NOT NULL DEFAULT 0 CHECK(compressed IN (0, 1))
          );
          CREATE TABLE IF NOT EXISTS trees (hash TEXT PRIMARY KEY, manifest TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS records (
            run TEXT NOT NULL, ordinal INTEGER NOT NULL, hash TEXT NOT NULL REFERENCES trees(hash),
            created_at INTEGER NOT NULL, message TEXT NOT NULL, PRIMARY KEY (run, ordinal)
          );
          CREATE INDEX IF NOT EXISTS records_age ON records(created_at);
          CREATE TABLE IF NOT EXISTS working (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), entries TEXT NOT NULL);
        SQL

        class << self
          def open(**options)
            new(**options).tap { |store| store.send(:initialize_database) }
          end

          def digest(root) = Digest::SHA256.hexdigest(File.realpath(root))[0, 16]

          # Discovery reads the existing record's root, including an absent root.
          # No second catalogue, initialization, repository command or file write.
          def roots(dir:, id: nil)
            if id
              id = id.to_s
              raise ArgumentError, "invalid checkpoint store: #{id.inspect}" unless STORE_ID.match?(id)
            end
            return [] unless File.directory?(dir)

            ids = id ? [id] : Dir.children(dir).grep(STORE_ID)
            ids.filter_map do |store_id|
              read_database(File.join(dir, store_id)) do |db|
                db.get_first_value("SELECT json_extract(message, '$.root') FROM records LIMIT 1")
              end
            end
          end

          def record_count(path)
            read_database(path) { |db| db.get_first_value("SELECT count(*) FROM records") } || 0
          end

          private

            def read_database(path)
              file = File.join(path, DATABASE_FILE)
              return nil unless File.file?(file)

              db = SQLite3::Database.new(file, readonly: true)
              db.statement_timeout = DEFAULT_CAPTURE_TIMEOUT_SECONDS * 1000
              yield db
            rescue SQLite3::Exception, SystemCallError
              nil
            ensure
              db&.close
            end
        end

        attr_reader :root, :path, :id, :dir, :protected_roots, :max_file_bytes, :max_tree_bytes,
          :capture_timeout_seconds, :retention_days

        def initialize(dir:, root:, protected_roots: [], excluded: [], log: nil, git: "git", clock: nil,
                       max_file_bytes: DEFAULT_MAX_FILE_BYTES, max_tree_bytes: DEFAULT_MAX_TREE_BYTES,
                       capture_timeout_seconds: DEFAULT_CAPTURE_TIMEOUT_SECONDS, retention_days: DEFAULT_RETENTION_DAYS)
          @root = File.realpath(root)
          raise ArgumentError, "checkpoint root must be a directory" unless File.directory?(@root)

          @dir = real_or_expanded(dir)
          @id = self.class.digest(@root)
          @path = File.join(@dir, @id)
          @protected_roots = protected_roots.map { |item| real_or_expanded(item) }
          raise ArgumentError, "checkpoint root is protected" if @protected_roots.any? { |item| beneath?(@root, item) }

          @excluded = (@protected_roots + excluded.map { |item| real_or_expanded(item) } + [@path]).freeze
          @max_file_bytes = Integer(max_file_bytes)
          @max_tree_bytes = Integer(max_tree_bytes)
          @capture_timeout_seconds = Float(capture_timeout_seconds)
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @git_binary = git
          @log = log
          @retention_days = Integer(retention_days)
          @mutex = Mutex.new
          @db = nil
          @project_exclude = nil
        end

        def capture(run_public_id:, outside: [], ignored: [])
          name = loop_name(run_public_id)
          operation do |deadline|
            existing = read_record(name, 0)
            existing || capture_locked(name, 0, deadline, outside: outside, ignored: ignored)
          end
        rescue TimedOut, Git::TimedOut
          skipped(name, Skip.new(reason: "timeout"))
        rescue Failed, Git::Failed, SystemCallError, IOError => error
          skipped(name, skip(error))
        end

        def restore(hash, undo_loop:)
          name = loop_name(undo_loop)
          undo = nil
          operation do |deadline|
            target = manifest(hash.to_s)
            next Refusal.new(code: "checkpoint_unknown", detail: hash.to_s) unless target
            if target.keys.any? { |relative| protected_path?(relative) }
              next Refusal.new(code: "restore_refused", detail: "protected_root_inside")
            end

            undo = capture_locked(name, undo_ordinal(name), deadline)
            if undo.skip?
              next Refusal.new(code: "restore_refused",
                detail: "the current tree could not be captured (#{undo.reason}); nothing was restored")
            end
            current = manifest(undo.hash)
            # Nested checkouts stay exactly as they are NOW, independent of target.
            nested = current.select { |_, entry| entry.mode == GITLINK }
            target = target.reject do |relative, entry|
              entry.mode == GITLINK || nested.keys.any? { |path| beneath?(relative, path) || beneath?(path, relative) }
            end.merge(nested)
            rows = differences(current, target)
            rows.each do |row|
              check(deadline)
              next unless row.fetch("status") == "A"

              collision = obstruction(row.fetch("path"), current, deadline)
              if collision
                return Refusal.new(code: "restore_refused",
                  detail: "uncaptured_path: #{collision}; nothing was restored", record: undo)
              end
            end
            # The undo has committed before the first filesystem change. A cancelled
            # restore may be partial, as with Git, but its undo remains discoverable.
            apply(current, target, rows, deadline)
            checkpoint(:restored, deadline)
            transaction { save_working(refresh_stats(target, deadline)) }
            removed = rows.count { |row| row.fetch("status") == "D" }
            @log&.info("checkpoint_restored", run_public_id: name, store: @id, from: undo.hash, to: hash.to_s,
              files: rows.length - removed, removed: removed)
            Restored.new(restored: hash.to_s, record: undo, files: rows.length - removed,
              removed: removed, nested: nested.keys)
          end
        rescue TimedOut, Failed, Git::Failed, Git::TimedOut, SystemCallError, IOError, Zlib::Error => error
          ExecutionContext.current&.raise_if_cancelled!
          before = undo && !undo.skip? ? undo : nil
          detail = tail(error.message)
          detail = "#{detail}; the tree before this call is #{before.hash}" if before
          Refusal.new(code: "restore_failed", detail: detail, record: before)
        end

        def records(run_public_id: nil)
          operation do |_deadline|
            rows = if run_public_id
              @db.execute("SELECT message FROM records WHERE run = ? ORDER BY ordinal", [loop_name(run_public_id)])
            else
              @db.execute("SELECT message FROM records ORDER BY run, ordinal")
            end
            rows.map { |row| Record.parse(row.fetch(0)) }
          end
        end

        def tree?(hash)
          operation { |_deadline| !@db.get_first_value("SELECT 1 FROM trees WHERE hash = ?", [hash.to_s]).nil? }
        rescue TimedOut
          false
        end

        def changed(from:, to:)
          operation { |_deadline| differences(manifest(from.to_s), manifest(to.to_s)) }
        end

        # A diff refreshes the same tracking/stat cache as capture, without a record.
        def changed_since(hash)
          operation do |deadline|
            target = manifest(hash.to_s)
            raise ArgumentError, "unknown checkpoint: #{hash}" unless target

            previous = working
            scan = scan_tree(previous, deadline)
            next Skip.new(reason: "tree_too_large", bytes: scan.bytes, files: scan.files) if scan.bytes > @max_tree_bytes

            transaction do
              entries = materialize(scan, previous, deadline)
              save_working(entries)
              checkpoint(:before_publish, deadline)
              differences(target, entries)
            end
          end
        rescue TimedOut, Git::TimedOut
          Skip.new(reason: "timeout")
        rescue Failed, Git::Failed, SystemCallError, IOError => error
          skip(error)
        end

        # Retention and collection share the existing root lock with capture/restore.
        # VACUUM is ordinary foreground maintenance under the larger prune deadline;
        # if interrupted after collection commits, the next prune can finish it.
        def prune(retention_days: @retention_days, now: Time.now)
          cutoff = now.to_f - Integer(retention_days) * 86_400
          operation(@capture_timeout_seconds * PRUNE_TIMEOUT_FACTOR) do |deadline|
            removed = transaction do
              @db.execute("DELETE FROM records WHERE created_at < ?", [cutoff])
              count = @db.changes
              @db.execute("DELETE FROM trees WHERE hash NOT IN (SELECT hash FROM records)")
              check(deadline)
              @db.execute(<<~SQL)
                DELETE FROM blobs WHERE hash NOT IN (
                  SELECT json_extract(entry.value, '$[1]')
                  FROM trees, json_each(trees.manifest) AS entry
                  WHERE json_extract(entry.value, '$[0]') != '160000'
                )
              SQL
              # The working index is a cache, not a retention root. Invalidate only
              # hashes whose bytes were collected; keep tracking and stat budgets.
              missing = @db.execute(<<~SQL).flatten
                SELECT entry.key FROM working, json_each(working.entries) AS entry
                LEFT JOIN blobs ON blobs.hash = json_extract(entry.value, '$.hash')
                WHERE json_extract(entry.value, '$.mode') != '160000' AND blobs.hash IS NULL
              SQL
              unless missing.empty?
                entries = working
                missing.each { |path| entries[path] = entries.fetch(path).with(hash: nil) }
                save_working(entries)
              end
              checkpoint(:before_prune_publish, deadline)
              count
            end
            check(deadline)
            @db.execute("VACUUM")
            @log&.info("checkpoints_pruned", store: @id, removed: removed)
            removed
          end
        end

        def size_bytes
          Dir.glob(File.join(@path, "**", "*"), File::FNM_DOTMATCH).sum { |file| File.file?(file) ? File.size(file) : 0 }
        end

        # The capture hook marks path-precise writes before execution,
        # including paths which do not exist yet. Tracked paths bypass ignore rules.
        def ignored(paths)
          relative = Array(paths).map(&:to_s).reject(&:empty?).uniq
          return [] if relative.empty?

          operation do |deadline|
            candidates = relative - working.keys
            excluded = candidates.select do |item|
              @excluded.any? { |prefix| beneath?(File.expand_path(item, @root), prefix) }
            end
            enabled = @project_exclude || candidates.any? { |item| ancestor_ignore?(item) }
            relative & (excluded + ignored_paths(candidates - excluded, deadline, enabled: enabled))
          end
        rescue TimedOut, Failed, Git::TimedOut, Git::Failed, SystemCallError, IOError
          []
        end

        private

          def initialize_database
            FileUtils.mkdir_p(@path, mode: 0o700)
            operation(OPEN_TIMEOUT_SECONDS) do |deadline|
              @db.execute("PRAGMA journal_mode = DELETE")
              @db.execute_batch(SCHEMA)
              unless @db.table_info("blobs").any? { |column| column.fetch("name") == "compressed" }
                @db.execute("ALTER TABLE blobs ADD COLUMN compressed INTEGER NOT NULL DEFAULT 0 CHECK(compressed IN (0, 1))")
              end
              discover_project(deadline)
              unless @db.get_first_value("SELECT 1 FROM working WHERE singleton = 1")
                transaction { save_working(seed(deadline)) }
              end
            end
          end

          # The source repository is read only. Plain roots use no Git at open; repo
          # roots retain HEAD tracking and info/exclude without parsing Git's formats.
          def discover_project(deadline)
            if File.exist?(File.join(@root, ".git"))
              @project_exclude = git(@root, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude", deadline: deadline).strip
            end
          end

          def seed(deadline)
            return {} unless @project_exclude

            outcome = git_command(@root).call("ls-tree", "-r", "-z", "HEAD", deadline: deadline)
            return {} unless outcome.ok? # An unborn checkout seeds nothing.

            outcome.stdout.split("\0").to_h do |line|
              metadata, relative = line.split("\t", 2)
              mode, _, oid = metadata.split(" ")
              relative.force_encoding(Encoding::UTF_8)
              signature = nil
              full = File.join(@root, relative)
              if mode != GITLINK && (File.file?(full) || File.symlink?(full))
                bytes = read_bytes(full, deadline)
                digest = oid.length == 40 ? Digest::SHA1 : Digest::SHA256
                signature = stat_signature(File.lstat(full)) if digest.hexdigest("blob #{bytes.bytesize}\0".b + bytes) == oid
              end
              [relative, Entry.new(mode: mode, hash: mode == GITLINK ? oid : nil, stat: signature)]
            end
          end

          def capture_locked(run, ordinal, deadline, outside: [], ignored: [])
            previous = working
            scan = scan_tree(previous, deadline)
            if scan.bytes > @max_tree_bytes
              return skipped(run, Skip.new(reason: "tree_too_large", bytes: scan.bytes, files: scan.files))
            end

            record = transaction do
              entries = materialize(scan, previous, deadline)
              body = JSON.generate(entries.sort.to_h.transform_values(&:content))
              hash = Digest::SHA256.hexdigest(body)
              @db.execute("INSERT OR IGNORE INTO trees(hash, manifest) VALUES (?, ?)", [hash, body])
              now = Time.now.utc
              captured = Record.new(run_public_id: run, hash: hash, store: @id, root: @root,
                captured_at: now.iso8601, files: entries.count { |_, entry| entry.mode != GITLINK },
                skipped: scan.skipped, nested: entries.filter_map { |relative, entry| relative if entry.mode == GITLINK },
                outside: outside, ignored: ignored)
              @db.execute("INSERT INTO records(run, ordinal, hash, created_at, message) VALUES (?, ?, ?, ?, ?)",
                [run, ordinal, hash, now.to_i, captured.message])
              save_working(entries)
              checkpoint(:before_publish, deadline)
              captured
            end
            @log&.info("checkpoint_captured", run_public_id: run, hash: record.hash, store: @id, files: record.files,
              skipped: record.skipped.length, nested: record.nested.length)
            record
          end

          def materialize(scan, previous, deadline)
            scan.entries.to_h do |relative, entry|
              check(deadline)
              full = File.join(@root, relative)
              old = previous[relative]
              if entry.mode == GITLINK
                [relative, entry]
              elsif old && old.hash && old.stat == entry.stat && old.mode == entry.mode && (!entry.hash || entry.hash == old.hash)
                [relative, entry.hash ? old.with(verified_at: entry.verified_at) : old]
              else
                bytes = read_bytes(full, deadline)
                digest = Digest::SHA256.hexdigest(bytes)
                write_blob(digest, bytes, deadline)
                checkpoint(:blob_written, deadline)
                [relative, entry.with(hash: digest, verified_at: Time.now.to_i)]
              end
            end
          end

          def write_blob(digest, bytes, deadline)
            return if @db.get_first_value("SELECT 1 FROM blobs WHERE hash = ?", [digest])

            packed = Zlib::Deflate.deflate(bytes, Zlib::BEST_SPEED)
            check(deadline)
            compressed = packed.bytesize < bytes.bytesize
            @db.execute("INSERT INTO blobs(hash, data, compressed) VALUES (?, ?, ?)",
              [digest, SQLite3::Blob.new(compressed ? packed : bytes), compressed ? 1 : 0])
          end

          def scan_tree(previous, deadline)
            entries = {}
            nested_dirty = []
            paths = {}
            (previous.keys + candidate_paths(deadline)).each do |relative|
              paths[relative] = true
              parent = File.dirname(relative)
              while parent != "." && !paths.key?(parent)
                paths[parent] = false
                parent = File.dirname(parent)
              end
            end
            # A tracked descendant may now sit under a nested checkout or symlink.
            # Visit ancestors as boundaries, without selecting ignored ancestor files.
            # Keep every file, symlink and nested checkout as a leaf.
            leaves = {}
            paths.keys.sort.each do |relative|
              check(deadline)
              full = File.join(@root, relative)
              if leaves[File.dirname(relative)] || @excluded.any? { |item| beneath?(full, item) }
                leaves[relative] = true
                next
              end

              begin
                stat = File.lstat(full)
              rescue Errno::ENOENT, Errno::ENOTDIR
                next
              end
              if stat.directory?
                if File.exist?(File.join(full, ".git"))
                  entries[relative] = Entry.new(mode: GITLINK, hash: nil, stat: nil)
                  leaves[relative] = true
                end
              elsif stat.file? || stat.symlink?
                entries[relative] = file_entry(full, stat, previous[relative], deadline) if paths.fetch(relative)
                leaves[relative] = true
              end
            end
            entries.each do |relative, entry|
              next unless entry.mode == GITLINK

              full = File.join(@root, relative)
              oid = git(full, "rev-parse", "HEAD", deadline: deadline).strip
              dirty = git(full, "status", "--porcelain=v1", "--untracked-files=all", deadline: deadline)
              nested_dirty << relative unless dirty.empty?
              entries[relative] = entry.with(hash: oid)
            end
            candidates = (previous.keys | entries.keys).select do |relative|
              old = previous[relative]
              now = entries[relative]
              old.nil? || now.nil? || old.mode != now.mode || old.stat != now.stat ||
                (now.hash && old.hash != now.hash) || (now.mode == GITLINK && nested_dirty.include?(relative))
            end
            skipped = []
            bytes = 0
            candidates.each do |relative|
              now = entries[relative]
              size = now && now.mode != GITLINK ? File.lstat(File.join(@root, relative)).size : 0
              if !previous.key?(relative) && size > @max_file_bytes
                skipped << relative
                entries.delete(relative)
              else
                bytes += size
              end
            end
            Scan.new(entries: entries, skipped: skipped.sort, files: candidates.length, bytes: bytes)
          end

          # A stat written in the same filesystem tick as its content read can
          # still describe a later equal-size edit. Verify
          # those bytes until the timestamp is older than the verification tick.
          # The second of slack also covers rounding at a seconds boundary.
          # Hashing here makes real edits spend the candidate budget, while an
          # unchanged recent file remains free of that budget.
          def file_entry(full, stat, previous, deadline)
            mode = stat.symlink? ? "120000" : (stat.mode & 0o111 != 0 ? "100755" : "100644")
            entry = Entry.new(mode: mode, hash: nil, stat: stat_signature(stat))
            return entry unless previous && previous.hash && previous.mode == mode && previous.stat == entry.stat &&
              previous.verified_at <= entry.stat[1] + 1

            entry.with(hash: Digest::SHA256.hexdigest(read_bytes(full, deadline)), verified_at: Time.now.to_i)
          end

          # A plain root needs no Git. Switch to Git enumeration as soon as an
          # applicable ignore file is found, before walking its directory's children.
          # Git prunes ignored trees; only selected or already tracked paths get statted.
          def candidate_paths(deadline)
            return git_paths(deadline) if @project_exclude

            paths = []
            Find.find(@root) do |full|
              check(deadline)
              stat = File.lstat(full)
              if (full != @root && File.basename(full) == ".git") || @excluded.any? { |item| beneath?(full, item) }
                Find.prune if stat.directory?
                next
              end
              relative = full.delete_prefix("#{@root}/")
              if stat.directory?
                if full != @root && File.exist?(File.join(full, ".git"))
                  paths << relative
                  Find.prune
                end
                return git_paths(deadline) if File.file?(File.join(full, ".gitignore"))
              elsif stat.file? || stat.symlink?
                paths << relative
              end
            end
            paths
          end

          def git_paths(deadline)
            excluded = @excluded.filter_map do |path|
              ":(exclude,literal)#{path.delete_prefix("#{@root}/")}" if beneath?(path, @root)
            end
            ignore_query(deadline).read("ls-files", "--others", "--exclude-standard", "-z", "--", ".", *excluded,
              deadline: deadline).split("\0").map { |path| path.delete_suffix("/").force_encoding(Encoding::UTF_8) }
          end

          # A path-precise write is affected only by ignore files in its ancestors.
          # Scanning unrelated subtrees here would defeat Git's ignored-tree pruning.
          def ancestor_ignore?(relative)
            directory = File.dirname(File.expand_path(relative, @root))
            while beneath?(directory, @root)
              return true if File.file?(File.join(directory, ".gitignore"))
              break if directory == @root

              directory = File.dirname(directory)
            end
            false
          end

          # Git owns ignore grammar and precedence. The private repository has no
          # content objects or index; it carries only the source's info/exclude rules.
          def ignore_query(deadline)
            rules = File.join(@path, "ignore-rules.git")
            unless File.directory?(rules)
              git(@root, "init", "--bare", "--quiet", rules, deadline: deadline)
            end
            File.binwrite(File.join(rules, "info", "exclude"), @project_exclude && File.file?(@project_exclude) ? File.binread(@project_exclude) : "")
            Git.new(binary: @git_binary, git_dir: rules, work_tree: @root, clock: @clock)
          end

          def ignored_paths(paths, deadline, enabled:)
            return [] if paths.empty? || !enabled

            outcome = ignore_query(deadline).call("check-ignore", "--no-index", "-z", "--stdin",
              stdin: paths.join("\0") + "\0", deadline: deadline)
            raise Git::Failed.new(["check-ignore"], outcome.status, outcome.stderr) unless [0, 1].include?(outcome.status.exitstatus)

            outcome.stdout.split("\0").map { |relative| relative.force_encoding(Encoding::UTF_8) }
          end

          def apply(current, target, rows, deadline)
            # Remove deepest files first; only empty directories are removed, so an
            # uncaptured child can never be removed recursively by a restore.
            rows.sort_by { |row| -row.fetch("path").count("/") }.each do |row|
              relative = row.fetch("path")
              next unless current.key?(relative) && current.fetch(relative).mode != GITLINK

              checkpoint(:before_file_remove, deadline)
              File.unlink(File.join(@root, relative))
              remove_empty_parents(File.dirname(File.join(@root, relative)))
            end
            rows.each do |row|
              relative = row.fetch("path")
              next if row.fetch("status") == "D"
              entry = target.fetch(relative)
              next if entry.mode == GITLINK

              checkpoint(:before_file_write, deadline)
              full = File.join(@root, relative)
              if File.directory?(full) && !File.symlink?(full)
                Find.find(full).to_a.reverse_each do |directory|
                  check(deadline)
                  Dir.rmdir(directory)
                end
              end
              FileUtils.mkdir_p(File.dirname(full))
              bytes, compressed = @db.get_first_row("SELECT data, compressed FROM blobs WHERE hash = ?", [entry.hash])
              bytes = Zlib::Inflate.inflate(bytes) if compressed == 1
              check(deadline)
              if entry.mode == "120000"
                File.symlink(bytes, full)
              else
                Tempfile.create([".checkpoint-", ".tmp"], File.dirname(full)) do |file|
                  file.binmode
                  offset = 0
                  while offset < bytes.bytesize
                    check(deadline)
                    file.write(bytes.byteslice(offset, CHUNK))
                    offset += CHUNK
                  end
                  file.flush
                  file.chmod(entry.mode == "100755" ? 0o755 : 0o644)
                  file.close
                  check(deadline)
                  File.rename(file.path, full)
                end
              end
              checkpoint(:file_written, deadline)
            end
          end

          def obstruction(relative, captured, deadline)
            parts = []
            relative.split("/").each do |component|
              parts << component
              prefix = parts.join("/")
              stat = File.lstat(File.join(@root, prefix))
              return captured.key?(prefix) && captured.fetch(prefix).mode != GITLINK ? nil : prefix unless stat.directory?
              return prefix if captured[prefix]&.mode == GITLINK
            end
            Find.find(File.join(@root, relative)) do |full|
              check(deadline)
              stat = File.lstat(full)
              next if stat.directory?
              name = full.delete_prefix("#{@root}/")
              return name unless captured.key?(name)
            end
            nil
          rescue Errno::ENOENT, Errno::ENOTDIR
            nil
          end

          def remove_empty_parents(directory)
            while directory != @root
              Dir.rmdir(directory)
              directory = File.dirname(directory)
            end
          rescue Errno::ENOTEMPTY, Errno::EEXIST
            nil
          end

          def read_bytes(full, deadline)
            return File.readlink(full).b if File.symlink?(full)

            bytes = +"".b
            File.open(full, "rb") do |file|
              while (chunk = file.read(CHUNK))
                check(deadline)
                bytes << chunk
                checkpoint(:file_chunk, deadline)
              end
            end
            bytes
          end

          def stat_signature(stat)
            [stat.size, stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec, stat.ino, stat.dev, stat.mode]
          end

          def refresh_stats(entries, deadline)
            entries.to_h do |relative, entry|
              check(deadline)
              [relative, entry.mode == GITLINK ? entry : entry.with(stat: stat_signature(File.lstat(File.join(@root, relative))), verified_at: Time.now.to_i)]
            end
          end

          def working
            JSON.parse(@db.get_first_value("SELECT entries FROM working WHERE singleton = 1")).transform_values { |value| Entry.parse(value) }
          end

          def save_working(entries)
            @db.execute("INSERT OR REPLACE INTO working(singleton, entries) VALUES (1, ?)", [JSON.generate(entries.transform_values(&:to_h))])
          end

          def manifest(hash)
            body = @db.get_first_value("SELECT manifest FROM trees WHERE hash = ?", [hash])
            body && JSON.parse(body).transform_values { |mode, digest| Entry.new(mode: mode, hash: digest, stat: nil) }
          end

          def differences(from, to)
            (from.keys | to.keys).sort.filter_map do |relative|
              left, right = from[relative], to[relative]
              next if left&.content == right&.content

              status = if left.nil?
                "A"
              elsif right.nil?
                "D"
              elsif left.mode[0, 3] != right.mode[0, 3]
                "T"
              else
                "M"
              end
              { "status" => status, "path" => relative }
            end
          end

          def read_record(run, ordinal)
            message = @db.get_first_value("SELECT message FROM records WHERE run = ? AND ordinal = ?", [run, ordinal])
            message && Record.parse(message)
          end

          def undo_ordinal(run)
            @db.get_first_value("SELECT coalesce(max(ordinal), 0) + 1 FROM records WHERE run = ?", [run])
          end

          # The store owns each connection for one operation. Configuration changes
          # can discard a handle while in-flight calls finish on theirs; no daemon
          # shutdown hook or idle connection lifecycle is needed.
          def operation(seconds = @capture_timeout_seconds)
            @mutex.synchronize do
              File.open(File.join(@path, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
                lock.flock(File::LOCK_EX)
                deadline = @clock.call + seconds
                check(deadline)
                db = SQLite3::Database.new(File.join(@path, DATABASE_FILE))
                begin
                  @db = db
                  check(deadline)
                  db.execute("PRAGMA foreign_keys = ON")
                  db.execute("PRAGMA synchronous = FULL")
                  ExecutionContext.with_cancel_signal(-> { db.interrupt }) { yield deadline }
                ensure
                  @db = nil
                  db.close
                end
              end
            end
          rescue SQLite3::InterruptException
            ExecutionContext.current&.raise_if_cancelled!
            raise TimedOut, "checkpoint deadline exceeded"
          rescue SQLite3::Exception => error
            ExecutionContext.current&.raise_if_cancelled!
            raise Failed, tail(error.message)
          end

          # Roll back on Ruby interrupts as well as database exceptions. The gem's
          # block transaction rescues StandardError only, so own the ensure here.
          def transaction
            @db.execute("BEGIN IMMEDIATE")
            committed = false
            begin
              answer = yield
              @db.execute("COMMIT")
              committed = true
              answer
            ensure
              @db.execute("ROLLBACK") if !committed && @db.transaction_active?
            end
          end

          def checkpoint(_stage, deadline) = check(deadline)

          def check(deadline)
            ExecutionContext.current&.raise_if_cancelled!
            raise TimedOut, "checkpoint deadline exceeded" if @clock.call >= deadline
            @db.statement_timeout = [((deadline - @clock.call) * 1000).ceil, 1].max if @db
          end

          def git_command(directory)
            Git.new(binary: @git_binary, work_tree: directory, clock: @clock)
          end

          def git(directory, *arguments, deadline:)
            git_command(directory).read(*arguments, deadline: deadline)
          end

          def skip(error)
            ExecutionContext.current&.raise_if_cancelled!
            Skip.new(reason: "checkpoint_failed", detail: tail(error.message))
          end

          def skipped(run, outcome)
            @log&.warn("checkpoint_skipped", run_public_id: run, store: @id, reason: outcome.reason,
              bytes: outcome.bytes, files: outcome.files, detail: outcome.detail)
            outcome
          end

          def tail(text) = text.to_s.strip.byteslice(-400, 400)&.scrub || text.to_s.strip

          def loop_name(value)
            name = value.to_s
            unless LOOP_NAME.match?(name) && !name.end_with?(".lock") && !name.include?("..")
              raise ArgumentError, "a checkpoint loop name is a public id, got #{value.inspect}"
            end
            name
          end

          def protected_path?(relative)
            @protected_roots.any? { |item| beneath?(File.join(@root, relative), item) }
          end

          def beneath?(path, directory) = path == directory || path.start_with?("#{directory}/")

          def real_or_expanded(path)
            expanded = File.expand_path(path)
            return File.realpath(expanded) if File.exist?(expanded)
            parent = File.dirname(expanded)
            parent == expanded ? expanded : File.join(real_or_expanded(parent), File.basename(expanded))
          end
      end
    end
  end
end

require_relative "store/review"
