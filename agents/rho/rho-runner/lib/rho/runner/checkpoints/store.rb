require "digest"
require "fileutils"
require "time"

module Rho
  class Runner
    module Checkpoints
      # THE SHADOW STORE: one bare git directory per root,
      # under the home's WORK root and never inside the project, holding
      # whole-tree captures of the root as parentless commits under
      # `refs/checkpoints/<loop>`, with the record as the commit's message.
      #
      # WHAT IT IS: the runner's own truth about the world before a loop's
      # first write (K-s3) — the kernel's `metadata.checkpoint` is a CACHE
      # of the `hash` and `store` a capture answers here. The store lives
      # in the work root by decision: project bytes, secrets
      # included, are the churny half an operator wipes or excludes from
      # backups, and its loss is graceful — `checkpoint_unknown`, the fork
      # made.
      # WHAT IT IS NOT: not per file, not per call, not a history (one commit per loop's first
      # write, one per restore under the request loop — never a branch), not a snapshot of
      # anything outside the root, not of a nested checkout's files (a gitlink), not of a
      # protected root inside the work root (excluded at capture, refused whole at restore —
      # evolution by incubation), not of an ignored path (`.gitignore` honoured; a secret
      # never enters a store under the home).
      #
      # THE LOCK IS A PAIR: a process-local Mutex — two worker
      # threads of one runner — AND a `flock` on `<store>/lock` opened PER
      # SECTION — two processes on one root; BSD flock is per open file
      # description, so one shared File would not exclude two threads.
      #
      # BOUNDED, NEVER A STALL: every git call runs in its own process
      # group under ONE deadline per operation (`Git`); over it the group
      # is killed and the operation answers `Skip {reason: timeout}`; a
      # tree over `max_tree_bytes` answers `Skip {reason: tree_too_large}`
      # and stages nothing; an untracked file over `max_file_bytes` is
      # excluded and listed in `skipped` (a TRACKED over-cap file — seeded from the project's index, or grown past the cap — is captured whole and costs its blob).
      class Store
        # The directory under a home's WORK root the stores live in —
        # `<work>/checkpoints/<digest>/`: the daemon opens a
        # store under it, the doctor lists what it holds.
        DIRECTORY = "checkpoints".freeze
        DEFAULT_MAX_FILE_BYTES = 2 * 1024 * 1024
        DEFAULT_MAX_TREE_BYTES = 256 * 1024 * 1024
        DEFAULT_CAPTURE_TIMEOUT_SECONDS = 30
        DEFAULT_RETENTION_DAYS = 7
        # The open — init, config, and on a checkout the one-time seed —
        # is not a capture and runs under its own fixed bound; a seed that
        # overruns leaves the index for the next capture's clock.
        OPEN_TIMEOUT_SECONDS = 60
        # A prune runs `gc`, which repacks the whole store: bounded by a
        # multiple of the capture's clock, killed as a group past it.
        PRUNE_TIMEOUT_FACTOR = 10
        REF_PREFIX = "refs/checkpoints/".freeze
        # A restore's undo ref: `refs/checkpoints/<loop>-undo-<n>`, a
        # SIBLING of the loop's own ref (a ref cannot be both a file and a
        # directory, so nothing nests under `<loop>`), `n` one past the
        # highest the loop holds — a fresh create-only ref per restore.
        UNDO_SUFFIX = "-undo-".freeze
        GITLINK = "160000".freeze
        INDEX_FILE = "index".freeze
        RESTORE_INDEX_FILE = "index.restore".freeze
        LOCK_FILE = "lock".freeze
        # The store's own settings (opencode's `snapshot/index.ts:324-333`,
        # hermes's `gc.auto=0`): CRLF untouched, links stored as links,
        # NO fsmonitor daemon (it detaches out of the process group), NO
        # auto-gc (git-config(1) `gc.autoDetach`), the many-files index.
        CONFIG = {
          "core.autocrlf" => "false", "core.symlinks" => "true", "core.fsmonitor" => "false",
          "gc.auto" => "0", "feature.manyFiles" => "true", "index.version" => "4",
          "core.untrackedCache" => "true",
        }.freeze
        # A loop's public id, as a ref name component: git-check-ref-format
        # refuses what this refuses, so a caller bug is an ArgumentError
        # here rather than a `git_failed` skip on every capture.
        LOOP_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
        STORE_ID = /\A[0-9a-f]{16}\z/
        SEED_EVENT = "checkpoint_seed_skipped".freeze

        Walk = Data.define(:files, :bytes, :skipped)
        private_constant :Walk

        attr_reader :id, :path, :root, :dir, :protected_roots, :max_file_bytes, :max_tree_bytes,
          :capture_timeout_seconds, :retention_days

        class << self
          # Opens (idempotently initialising) the store for `root` under
          # `dir`: `<dir>/<digest>/`, `digest` the first 16 hex of the
          # SHA-256 of the root's real path. `protected_roots` are absolute
          # paths never captured and never restored; `excluded` are absolute
          # paths never captured (the runner's spill directory). A root at
          # or under a protected root has no store: ArgumentError.
          def open(dir:, root:, protected_roots: [], excluded: [], log: nil, git: "git", clock: nil,
                   max_file_bytes: DEFAULT_MAX_FILE_BYTES, max_tree_bytes: DEFAULT_MAX_TREE_BYTES,
                   capture_timeout_seconds: DEFAULT_CAPTURE_TIMEOUT_SECONDS, retention_days: DEFAULT_RETENTION_DAYS)
            new(dir: dir, root: root, protected_roots: protected_roots, excluded: excluded, log: log, git: git,
              clock: clock, max_file_bytes: max_file_bytes, max_tree_bytes: max_tree_bytes,
              capture_timeout_seconds: capture_timeout_seconds, retention_days: retention_days).send(:init!)
          end

          def digest(root) = Digest::SHA256.hexdigest(File.realpath(root))[0, 16]

          # The existing record owns its root; a restarted host needs no
          # second persistent root-to-store catalogue to route a restore.
          def roots(dir:, id: nil)
            if id
              id = id.to_s
              raise ArgumentError, "invalid checkpoint store: #{id.inspect}" unless STORE_ID.match?(id)
            end
            return [] unless File.directory?(dir)

            ids = id ? [id] : Dir.children(dir).grep(STORE_ID)
            ids.filter_map do |store_id|
              path = File.join(dir, store_id)
              next unless File.directory?(path)

              clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
              contents = Git.new(binary: "git", git_dir: path, work_tree: path, clock: clock)
                .read("for-each-ref", "--count=1", "--format=%(contents)", REF_PREFIX,
                  deadline: clock.call + DEFAULT_CAPTURE_TIMEOUT_SECONDS)
              Record.parse(contents)&.root
            rescue Git::Failed, Git::TimedOut, SystemCallError, IOError
              nil
            end
          end

          # The records a store at `path` holds — the refs under
          # `REF_PREFIX`, every one a capture or an undo — counted through
          # git itself (a prune packs them; the loose files are not the
          # count), under the capture clock and the store's neutral
          # environment, WITHOUT opening: an open inits, re-configures and
          # seeds, and a doctor's read must write nothing. A store git
          # cannot read, or reads past the clock, counts as none.
          def record_count(path, git: "git", clock: nil)
            clock ||= -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            deadline = clock.call + DEFAULT_CAPTURE_TIMEOUT_SECONDS
            Git.new(binary: git, git_dir: path, work_tree: path, clock: clock)
              .read("for-each-ref", "--format=%(refname)", REF_PREFIX, deadline: deadline)
              .lines.length
          rescue Git::Failed, Git::TimedOut, SystemCallError
            0
          end
        end

        def initialize(dir:, root:, protected_roots:, excluded:, log:, git:, clock:, max_file_bytes:,
                       max_tree_bytes:, capture_timeout_seconds:, retention_days:)
          @root = File.realpath(root)
          raise ArgumentError, "the checkpoint root must be a directory: #{root}" unless File.directory?(@root)

          @protected_roots = Array(protected_roots).map { |protected| real_or_expanded(protected) }.uniq.freeze
          if @protected_roots.any? { |p| @root == p || @root.start_with?("#{p}/") }
            raise ArgumentError, "the checkpoint root lies under a protected root: #{@root}"
          end

          @dir = real_or_expanded(dir)
          @id = Store.digest(@root)
          @path = File.join(@dir, @id)
          @excluded = Array(excluded).map { |p| real_or_expanded(p) }.freeze
          @log = log
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @git = Git.new(binary: git, git_dir: @path, work_tree: @root, clock: @clock)
          @max_file_bytes = Integer(max_file_bytes)
          @max_tree_bytes = Integer(max_tree_bytes)
          @capture_timeout_seconds = Float(capture_timeout_seconds)
          @retention_days = Integer(retention_days)
          @mutex = Mutex.new
          @project = nil
        end

        # ---- the four verbs ----

        # THE CAPTURE: the whole tree, `.gitignore` honoured, bounded, ONE
        # per loop. Answers the `Record` — the loop's EXISTING record when
        # the ref already stands (the create-only ref is the idempotency
        # key: a runner restart cannot overwrite a loop's first tree) — or
        # a `Skip`. A restore's undo is NOT this verb: it is always a fresh
        # record under its own ref (`capture_undo_locked`). `outside` and
        # `ignored` are the hook's lists, recorded and
        # carried on the key.
        def capture(loop:, outside: [], ignored: [])
          name = loop_name(loop)
          with_lock { capture_locked(name, outside: outside, ignored: ignored) }
        end

        # THE RESTORE: the target must be a tree of THIS store; no
        # entry of it under a protected root (refused WHOLE); the UNDO
        # captured first under `undo_loop` — ALWAYS a fresh record, the
        # tree as it stands NOW, so two restores in one request loop answer
        # two undos, each its own pre-image (a restore that cannot be
        # undone is not performed); then `git read-tree --reset -u`
        # writes only what differs, removes what the undo holds and the
        # target lacks, and refreshes the stat cache. Any current path the
        # undo omitted must be preserved, so an obstructed addition is
        # refused before that primitive. Gitlinks are never written or
        # removed: the target is re-shaped in a temporary index to carry exactly the
        # undo's gitlinks. Answers `Restored` or `Refusal`.
        def restore(hash, undo_loop:)
          target = hash.to_s
          name = loop_name(undo_loop)
          with_lock { restore_locked(target, name) }
        end

        # Every record under the prefix, oldest ref first by ref name,
        # each with `present` (the tree still in the store). For one loop:
        # its own capture, then its undos in order — the records whose
        # `loop` IS the name (the undo pattern is a glob; a stranger loop
        # spelled `<loop>-undo-…` is nobody's undo).
        def records(loop: nil)
          name = loop.nil? ? nil : loop_name(loop)
          with_deadline do |deadline|
            refs = name.nil? ? read_refs(deadline, REF_PREFIX) : read_refs(deadline, ref_name(name), undo_pattern(name))
            presence = present_trees(refs.map { |entry| entry.fetch(:tree) }, deadline)
            refs.filter_map do |entry|
              record = Record.parse(entry.fetch(:contents), present: presence.include?(entry.fetch(:tree)))
              record if record && (name.nil? || record.loop == name)
            end
          end
        end

        # `{status, path}` rows between two trees — NO work-tree pass: the
        # per-turn diff (turn N's changes = N's tree → N+1's), R-s4.
        def changed(from:, to:)
          with_deadline do |deadline|
            parse_status(@git.read("diff-tree", "-r", "--name-status", "-z", from.to_s, to.to_s, deadline: deadline))
          end
        end

        # The tree vs NOW: the current tree staged under the capture's caps
        # and clock (a `Skip` on overrun), then `diff --cached`.
        def changed_since(hash)
          with_lock do
            with_deadline do |deadline|
              sync_excludes(deadline)
              walk = walk_candidates(deadline)
              next Skip.new(reason: "tree_too_large", bytes: walk.bytes, files: walk.files) if walk.bytes > @max_tree_bytes

              append_excludes(walk.skipped)
              stage_tree(deadline)
              parse_status(@git.read("diff", "--cached", "--name-status", "-z", hash.to_s, deadline: deadline))
            end
          rescue Git::TimedOut
            Skip.new(reason: "timeout")
          rescue Git::Failed => error
            Skip.new(reason: "git_failed", detail: tail(error.stderr))
          end
        end

        # WHICH OF `paths` (relative to the root) the tree cannot hold:
        # `git check-ignore` under the store's excludes — the
        # project's `.gitignore`, its `info/exclude`, the protected roots,
        # the spill directory — synced first, as a capture syncs them. A
        # tracked path is never ignored (gitignore(1): tracked files are not
        # subject to exclude rules); a path that does not exist yet answers
        # by pattern alone, so a `write` creating `.env` is named before it
        # lands. Answers `[]` on a timeout or a git failure: the list is a
        # mark on the key, never a gate.
        def ignored(paths)
          relative = Array(paths).map(&:to_s).reject(&:empty?).uniq
          return [] if relative.empty?

          with_lock do
            with_deadline do |deadline|
              sync_excludes(deadline)
              outcome = @git.call("check-ignore", "-z", "--stdin", stdin: "#{relative.join("\0")}\0", deadline: deadline)
              # 0 = some ignored, 1 = none, 128 = an error: the list on 0 alone.
              outcome.status.exitstatus.zero? ? outcome.stdout.split("\0").map { |path| utf8(path) } : []
            end
          end
        rescue Git::TimedOut, Git::Failed, SystemCallError, IOError
          []
        end

        # Is `hash` a tree this store holds?
        def tree?(hash)
          with_deadline do |deadline|
            outcome = @git.call("cat-file", "-t", hash.to_s, deadline: deadline)
            outcome.ok? && outcome.stdout.strip == "tree"
          end
        rescue Git::TimedOut
          false
        end

        # Drops the refs older than the retention and repacks; answers the
        # count dropped. Run on the daemon's `:startup`, under the
        # lock and a bounded clock; a gc killed mid-way is finished by the
        # next prune.
        def prune(retention_days: @retention_days, now: Time.now)
          cutoff = now.to_f - (Integer(retention_days) * 86_400)
          with_lock do
            with_deadline(@capture_timeout_seconds * PRUNE_TIMEOUT_FACTOR) do |deadline|
              stale = read_refs(deadline, REF_PREFIX).select { |entry| entry.fetch(:created_at) < cutoff }
              stale.each { |entry| @git.read("update-ref", "-d", entry.fetch(:ref), deadline: deadline) }
              @git.read("gc", "--prune=now", "--quiet", deadline: deadline)
              @log&.info("checkpoints_pruned", store: @id, removed: stale.length)
              stale.length
            end
          end
        end

        # Bytes the store's git directory holds, for a doctor row.
        def size_bytes
          Dir.glob(File.join(@path, "**", "*"), File::FNM_DOTMATCH).sum do |file|
            File.file?(file) ? File.size(file) : 0
          end
        end

        private

          # ---- open ----

          # Idempotent: `git init --bare` on an existing store recreates
          # what a full pack removed (`refs/heads`, hermes's failure); the
          # config is re-set; a checkout root gets the alternates and, on
          # the FIRST open, the index seeded from its HEAD tree.
          def init!
            FileUtils.mkdir_p(@dir, mode: 0o700)
            FileUtils.mkdir_p(@path, mode: 0o700)
            with_lock do
              with_deadline(OPEN_TIMEOUT_SECONDS) do |deadline|
                @git.read("init", "--bare", "--quiet", @path, deadline: deadline, redirect: false)
                CONFIG.each { |key, value| @git.read("config", key, value, deadline: deadline) }
                FileUtils.mkdir_p(File.join(@path, "info"))
                @project = discover_project(deadline)
                seed(deadline) if @project && !File.exist?(File.join(@path, INDEX_FILE))
              end
            end
            self
          end

          # The project's own git, when the ROOT is exactly a checkout's
          # top level (a subdirectory of a repository is not a checkout of
          # its own and gets no alternate). Read-only.
          def discover_project(deadline)
            top = @git.call("rev-parse", "--show-toplevel", deadline: deadline, redirect: false)
            return nil unless top.ok? && File.realpath(top.stdout.strip) == @root

            objects = @git.read("rev-parse", "--path-format=absolute", "--git-path", "objects", deadline: deadline, redirect: false).strip
            exclude = @git.read("rev-parse", "--path-format=absolute", "--git-path", "info/exclude", deadline: deadline, redirect: false).strip
            File.write(File.join(@path, "objects", "info", "alternates"), "#{objects}\n")
            { objects: objects, exclude: exclude }
          rescue Git::Failed
            nil
          end

          # opencode's seed: the checkout's HEAD tree read into the store's
          # index (through the alternate, no copy) and refreshed, so the
          # first capture is a stat walk. An unborn HEAD seeds nothing; a
          # seed that overruns leaves the index as `read-tree` left it —
          # the next capture hashes it once, under its own clock.
          def seed(deadline)
            head = @git.call("rev-parse", "--verify", "--quiet", "HEAD^{tree}", deadline: deadline, redirect: false)
            return unless head.ok?

            @git.read("read-tree", head.stdout.strip, deadline: deadline)
            @git.read("update-index", "--refresh", "-q", deadline: deadline)
          rescue Git::TimedOut, Git::Failed => error
            @log&.warn(SEED_EVENT, store: @id, error_class: error.class.name)
          end

          # ---- capture ----

          # The loop's FIRST tree: the existing record when the ref stands
          # (create-only; a runner restart never overwrites it), else a
          # capture under the loop's own ref — a ref that stood by the time
          # of the write (a race with another process) is read back.
          def capture_locked(name, outside:, ignored:)
            with_deadline do |deadline|
              existing = read_record(name, deadline)
              return existing if existing

              capture_tree(name, name, deadline, outside: outside, ignored: ignored) do |tree, record|
                write_ref(name, tree, record, deadline) || read_record(name, deadline) || record
              end
            end
          rescue Git::TimedOut, Git::Failed, SystemCallError, IOError => error
            skipped(name, skip_for(error))
          end

          # A restore's UNDO: ALWAYS a fresh record — the tree as it stands
          # NOW — under a minted sibling ref the create-only write can
          # never collide with (the lock is held; a collision is a store
          # bug and answers a skip, never another restore's undo).
          def capture_undo_locked(name)
            with_deadline do |deadline|
              ref = undo_ref(name, deadline)
              capture_tree(ref, name, deadline, outside: [], ignored: []) do |tree, record|
                write_ref(ref, tree, record, deadline) ||
                  skipped(name, Skip.new(reason: "git_failed", detail: "the undo ref #{ref} already stood"))
              end
            end
          rescue Git::TimedOut, Git::Failed, SystemCallError, IOError => error
            skipped(name, skip_for(error))
          end

          # The next undo ref under `name`: one past the highest suffix the
          # loop holds (a pruned lower one is never reused).
          def undo_ref(name, deadline)
            prefix = "#{ref_name(name)}#{UNDO_SUFFIX}"
            highest = read_refs(deadline, undo_pattern(name)).map { |entry| entry.fetch(:ref).delete_prefix(prefix).to_i }.max
            "#{name}#{UNDO_SUFFIX}#{highest.to_i + 1}"
          end

          def undo_pattern(name) = "#{ref_name(name)}#{UNDO_SUFFIX}*"

          # THE TREE, staged under the caps and written; the block writes
          # the ref and answers the record. `ref` names the ref, `loop` the
          # record's loop (the same for a first capture; the request loop
          # for an undo).
          def capture_tree(ref, loop, deadline, outside:, ignored:)
            sync_excludes(deadline)
            walk = walk_candidates(deadline)
            if walk.bytes > @max_tree_bytes
              return skipped(loop, Skip.new(reason: "tree_too_large", bytes: walk.bytes, files: walk.files))
            end

            append_excludes(walk.skipped)
            stage_tree(deadline)
            tree = @git.read("write-tree", deadline: deadline).strip
            listing = index_listing(deadline)
            record = Record.new(
              loop: loop, hash: tree, store: @id, root: @root, captured_at: Time.now.utc.iso8601,
              files: listing.count { |mode, _, _| mode != GITLINK }, skipped: walk.skipped.map { |p| utf8(p) },
              nested: listing.filter_map { |mode, _, p| utf8(p) if mode == GITLINK }, outside: outside,
              ignored: ignored
            )
            yield(tree, record)
          end

          # One commit, one create-only ref, logged when it lands. nil when
          # the ref already stood: the caller decides what that means.
          def write_ref(ref, tree, record, deadline)
            commit = @git.read("commit-tree", tree, "-F", "-", stdin: record.message, deadline: deadline).strip
            created = @git.call("update-ref", ref_name(ref), commit, "", deadline: deadline)
            return nil unless created.ok?

            @log&.info("checkpoint_captured", loop: record.loop, hash: tree, store: @id, files: record.files,
              skipped: record.skipped.length, nested: record.nested.length)
            record
          end

          def skip_for(error)
            case error
            when Git::TimedOut then Skip.new(reason: "timeout")
            when Git::Failed then Skip.new(reason: "git_failed", detail: tail(error.stderr))
            else Skip.new(reason: "git_failed", detail: "#{error.class}: #{error.message}")
            end
          end

          def skipped(name, skip)
            @log&.warn("checkpoint_skipped", loop: name, store: @id, reason: skip.reason, bytes: skip.bytes,
              files: skip.files, detail: skip.detail)
            skip
          end

          # THE CANDIDATE LIST (opencode's two): tracked-and-changed plus
          # untracked-not-ignored; a `stat` walk bounds it — an untracked
          # file over the per-file cap joins `skipped`; the total decides
          # the tree cap. A deleted tracked file weighs nothing; a nested
          # checkout is listed as its directory and weighs nothing.
          def walk_candidates(deadline)
            tracked = @git.read("diff-files", "--name-only", "-z", deadline: deadline).split("\0")
            untracked = @git.read("ls-files", "--others", "--exclude-standard", "--full-name", "-z", deadline: deadline)
              .split("\0")
            skipped = []
            bytes = 0
            tracked.each { |path| bytes += size_of(path) }
            untracked.each do |path|
              size = size_of(path)
              if size > @max_file_bytes
                skipped << path
              else
                bytes += size
              end
            end
            Walk.new(files: tracked.length + untracked.length, bytes: bytes, skipped: skipped.sort)
          end

          def size_of(path)
            stat = File.lstat(File.join(@root, path))
            stat.directory? ? 0 : stat.size
          rescue SystemCallError
            0
          end

          # THE STAGE: `add --all` under the excludes, then the exclusion
          # set UNSTAGED by path — `info/exclude` does not affect a path the
          # index already tracks (gitignore(1)), and a seeded checkout
          # tracks its own protected root (this repository's dev layout
          # binds the monorepo, with rho's checkout under it): a protected
          # root, the spill directory and the store are never in a tree
          # whatever the index held before.
          def stage_tree(deadline)
            @git.read("add", "--all", "--", ".", deadline: deadline)
            unstaged = exclusion_paths
            return if unstaged.empty?

            @git.read("rm", "-r", "--cached", "--quiet", "--ignore-unmatch", "--", *unstaged, deadline: deadline)
          end

          # The excluded directories, the protected roots and the store,
          # relative to the root — those strictly inside it.
          def exclusion_paths
            (@excluded + @protected_roots + [@path]).filter_map { |absolute| relative_to_root(absolute) }.uniq
          end

          # `<store>/info/exclude`, rewritten per capture: the project's
          # own `.git/info/exclude`, the excluded directories under the
          # root (the spill directory), every protected root under the
          # root, and the store itself when it lies under the root.
          def sync_excludes(_deadline)
            lines = []
            project_exclude = @project&.fetch(:exclude)
            lines << File.read(project_exclude, encoding: Encoding::BINARY) if project_exclude && File.file?(project_exclude)
            exclusion_paths.each { |relative| lines << "/#{escape_pattern(relative)}/" }
            File.write(exclude_path, "#{lines.join("\n")}\n", encoding: Encoding::BINARY)
          end

          def append_excludes(paths)
            return if paths.empty?

            File.open(exclude_path, "ab") { |file| paths.each { |path| file.write("/#{escape_pattern(path)}\n") } }
          end

          def exclude_path = File.join(@path, "info", "exclude")

          # The path relative to the root when strictly inside it, else nil.
          def relative_to_root(absolute)
            prefix = "#{@root}/"
            absolute.start_with?(prefix) ? absolute.delete_prefix(prefix) : nil
          end

          # gitignore(1)'s pattern characters, escaped so a path is a path.
          def escape_pattern(path)
            path.b.gsub(/[\\\[\]*?]/) { |char| "\\#{char}" }.gsub(/ \z/, "\\ ")
          end

          # `[mode, sha, path]` for every index entry.
          def index_listing(deadline, index: nil)
            @git.read("ls-files", "-s", "-z", deadline: deadline, index: index).split("\0").map do |line|
              meta, path = line.split("\t", 2)
              mode, sha, _stage = meta.split(" ")
              [mode, sha, path]
            end
          end

          # ---- restore ----

          def restore_locked(target, name)
            undo = nil
            with_deadline do |deadline|
              known = @git.call("cat-file", "-t", target, deadline: deadline)
              unless known.ok? && known.stdout.strip == "tree"
                return Refusal.new(code: "checkpoint_unknown", detail: target)
              end

              paths = @git.read("ls-tree", "-r", "--name-only", "-z", target, deadline: deadline).split("\0")
              return protected_refusal if paths.any? { |path| protected_path?(path) }

              undo = capture_undo_locked(name)
              if undo.skip?
                return Refusal.new(code: "restore_refused",
                  detail: "the current tree could not be captured (#{undo.reason}); nothing was restored")
              end

              listing = index_listing(deadline)
              return protected_refusal if listing.any? { |_, _, path| protected_path?(path) }

              gitlinks = listing.select { |mode, _, _| mode == GITLINK }.map { |_, sha, path| [sha, path] }
              adjusted = reshape_target(target, gitlinks, deadline)
              diff = @git.read("diff-tree", "-r", "--name-status", "-z", undo.hash, adjusted, deadline: deadline)
              captured = listing.to_h { |_, _, path| [path, true] }
              diff.split("\0").each_slice(2) do |status, path|
                next unless status == "A"

                collision = uncaptured_obstruction(path, captured, deadline)
                if collision
                  return Refusal.new(code: "restore_refused",
                    detail: "uncaptured_path: #{utf8(collision)}; nothing was restored", record: undo)
                end
              end

              rows = parse_status(diff)
              @git.read("read-tree", "--reset", "-u", adjusted, deadline: deadline)
              removed = rows.count { |row| row.fetch("status").start_with?("D") }
              @log&.info("world_restored", loop: name, store: @id, from: undo.hash, to: target,
                files: rows.length - removed, removed: removed)
              Restored.new(restored: target, record: undo, files: rows.length - removed, removed: removed,
                nested: gitlinks.map { |_, path| utf8(path) })
            end
          rescue Git::TimedOut, Git::Failed, SystemCallError, IOError => error
            detail = (error in Git::Failed) ? tail(error.stderr) : "#{error.class}: #{error.message}"
            before = undo && !undo.skip? ? undo : nil
            detail = "#{detail}; the tree before this call is #{before.hash}" if before
            Refusal.new(code: "restore_failed", detail: detail, record: before)
          end

          # Git's reset and two-tree merge both overwrite ignored paths.
          # Only additions can displace a path absent from the undo; a
          # directory replacement asks git about that directory alone,
          # without the excludes that kept those bytes out of the capture.
          def uncaptured_obstruction(path, captured, deadline)
            relative = []
            path.split("/").each do |component|
              relative << component
              prefix = relative.join("/")
              stat = File.lstat(File.join(@root, prefix))
              return captured.key?(prefix) ? nil : prefix unless stat.directory?
            end

            @git.read("ls-files", "--others", "--directory", "--no-empty-directory", "-z",
              "--", ":(literal)#{path}", deadline: deadline).split("\0").first
          rescue Errno::ENOENT, Errno::ENOTDIR
            nil
          end

          # The target tree with EXACTLY the undo's gitlinks, built
          # in a temporary index so the store's own — the undo, stat cache
          # fresh — is untouched until the one primitive runs on it.
          def reshape_target(target, gitlinks, deadline)
            temp = File.join(@path, RESTORE_INDEX_FILE)
            File.delete(temp) if File.exist?(temp)
            @git.read("read-tree", target, deadline: deadline, index: temp)
            kept = gitlinks.map(&:last)
            index_listing(deadline, index: temp).each do |mode, _, path|
              next unless mode == GITLINK && !kept.include?(path)

              @git.read("update-index", "--force-remove", "--", path, deadline: deadline, index: temp)
            end
            gitlinks.each do |sha, path|
              @git.read("update-index", "--add", "--cacheinfo", "#{GITLINK},#{sha},#{path}", deadline: deadline, index: temp)
            end
            @git.read("write-tree", deadline: deadline, index: temp).strip
          ensure
            File.delete(temp) if temp && File.exist?(temp)
          end

          def protected_refusal = Refusal.new(code: "restore_refused", detail: "protected_root_inside")

          def protected_path?(path)
            @protected_roots.any? do |absolute|
              relative = relative_to_root(absolute)
              relative && (path == relative || path.start_with?("#{relative}/"))
            end
          end

          # ---- reads ----

          # `{ref, commit, tree, created_at, contents}` per ref under the
          # patterns (a literal prefix or a glob), in ONE call: the record
          # rides `%(contents)`.
          def read_refs(deadline, *patterns)
            output = @git.read("for-each-ref",
              "--format=%(refname)%00%(objectname)%00%(tree)%00%(creatordate:unix)%00%(contents)%00",
              *patterns, deadline: deadline)
            fields = output.split("\0")
            fields.each_slice(5).filter_map do |ref, commit, tree, created, contents|
              next if contents.nil?

              { ref: ref.delete_prefix("\n"), commit: commit, tree: tree, created_at: created.to_i,
                contents: contents.dup.force_encoding(Encoding::UTF_8).scrub }
            end
          end

          def read_record(name, deadline)
            entry = read_refs(deadline, ref_name(name)).first
            entry && Record.parse(entry.fetch(:contents))
          end

          def present_trees(trees, deadline)
            return [] if trees.empty?

            @git.read("cat-file", "--batch-check", stdin: "#{trees.uniq.join("\n")}\n", deadline: deadline)
              .lines.filter_map { |line| line.split(" ").first unless line.include?(" missing") }
          end

          # `status\0path\0` pairs; a rename (never asked for) carries two.
          def parse_status(output)
            fields = output.split("\0")
            rows = []
            until fields.empty?
              status = fields.shift
              path = fields.shift
              path = fields.shift if status.start_with?("R", "C")
              rows << { "status" => utf8(status), "path" => utf8(path) } if path
            end
            rows
          end

          # A path off a `-z` listing is BYTES; a record and a row are JSON.
          def utf8(bytes) = bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub

          # ONE SPELLING: `@root` is its real path, and every path compared
          # against it (`relative_to_root`) must carry the same spelling —
          # a symlinked `/var`, a linked $HOME, `RHO_WORK_DIR` inside the
          # root. A path that does not exist yet (the store dir before its
          # first init, a spill directory before its first spill) is
          # real-pathed through its deepest existing ancestor.
          def real_or_expanded(path)
            expanded = File.expand_path(path)
            return File.realpath(expanded) if File.exist?(expanded)

            parent = File.dirname(expanded)
            return expanded if parent == expanded

            File.join(real_or_expanded(parent), File.basename(expanded))
          end

          # ---- plumbing ----

          def ref_name(name) = "#{REF_PREFIX}#{name}"

          def loop_name(loop)
            name = loop.to_s
            return name if name.match?(LOOP_NAME) && !name.end_with?(".lock") && !name.include?("..")

            raise ArgumentError, "a checkpoint loop name is a public id, got #{loop.inspect}"
          end

          def tail(text, bytes = 400)
            value = text.to_s.strip
            value.bytesize > bytes ? value.byteslice(-bytes, bytes).scrub : value
          end

          def with_deadline(seconds = @capture_timeout_seconds)
            yield(@clock.call + seconds)
          end

          # The pair: the Mutex, then the flock, opened per section.
          def with_lock
            @mutex.synchronize do
              File.open(File.join(@path, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |file|
                file.flock(File::LOCK_EX)
                begin
                  yield
                ensure
                  # Git has reaped its process group before returning or raising.
                  # Keep the store lock until killed writers' index locks are gone.
                  FileUtils.rm_f([INDEX_FILE, RESTORE_INDEX_FILE].map { |name| File.join(@path, "#{name}.lock") })
                end
              end
            end
          end
      end
    end
  end
end
