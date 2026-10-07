require "digest"

module Rho
  class Runner
    # The execution environment a tool handler closes over: where relative
    # paths resolve, where captures land (large output spills, screenshots,
    # a page's overflow — `artifacts_dir`, placed by `artifacts_dir_for`),
    # how file mutations serialize, and how long a command may run.
    #
    # THERE IS NO PATH CONFINEMENT, and that is the product rather than an
    # oversight: rho reads and writes the user's real files, so absolute and
    # `~` paths pass through untouched. Isolation is a runner-role and
    # container concern. The ONE confined thing is the `subdir` selector,
    # which may only narrow within the bound root — it is a convenience for
    # relative paths, never an independent axis.
    #
    # ONE PER ROOT SET: a conversation bound to another
    # root runs its tools under an env built for that root set —
    # `directories` the rest of the set, `documents_root` where the skills
    # the runner ANNOUNCED load from (the default root's), the
    # root's own captures and checkpoint store — sharing the runner's one
    # mutation queue and process table. Nothing here confines a path on the
    # set either; `in_roots?` is a predicate for the port's routing (E2).
    class ToolEnv
      # The directory under a host's WORK dir the captures of every root
      # live in, one subdirectory per root.
      ARTIFACTS_DIRECTORY = "artifacts".freeze
      # A capture's name carries this much of its content's digest.
      CAPTURE_DIGEST_CHARS = 16

      attr_reader :root, :artifacts_dir, :mutation_queue, :bash_timeout_seconds
      # THE REST OF THE ROOT SET, spelled as the root is (expanded; never
      # required to exist). Empty for the default root.
      attr_reader :directories
      # WHERE `skill` LOADS SCAN: the root whose `.agents/skills` this
      # runner announced — the default root's, on a placement built over a
      # bound root — nil when the env's own root is the announced one.
      attr_reader :documents_root
      # THE HOST'S PROCESS TABLE, if the host has one. A daemon builds it
      # once at boot and hands it here so the tools that start a server and
      # the routes that list it share one table without a process-global;
      # a standalone runner has no daemon to own a process and hands nil,
      # and a tool that needs the table says so instead of starting one.
      attr_reader :processes
      # THE HOST'S CHECKPOINT STORE, if the host opened one: the
      # daemon opens `Checkpoints::Store` once per real root, where it
      # builds this env at placement, and hands it here so `checkpoint_restore`
      # and `checkpoints` reach the same store the capture hook writes (the
      # hook reads it off the context's placement); a host with none — a
      # standalone runner has nowhere to keep a pre-image — hands nil, and
      # the two tools answer `checkpoints_disabled`.
      attr_reader :checkpoints
      # A host's existing stores, selected by id or listed for a loop's
      # checkpoint lookup. A standalone runner holds only its own store.
      attr_reader :checkpoint_resolver

      # WHERE A ROOT'S CAPTURES ARE PLACED: `<work_dir>/artifacts/
      # <digest>/`, `digest` the checkpoint store's key for the same root
      # (the first 16 hex of the SHA-256 of its real path — one root, one
      # key in both trees; the root exists). A bash spill, a screenshot, a
      # page's overflow are rho's own bookkeeping, and rho writes the
      # person's files on the person's word only — never its bookkeeping
      # into their tree, where an `artifacts/` is noise in every `git
      # status` the model runs and a stray directory in a graded one. Two
      # roots never share a directory. The work dir is taken by its real
      # path where it exists, so a host whose work dir lies inside the root
      # can hand the placed directory to its checkpoint store's exclusions
      # (the store keys on real paths) and the store skips it as its own.
      def self.artifacts_dir_for(root:, work_dir:)
        work = File.exist?(work_dir) ? File.realpath(work_dir) : File.expand_path(work_dir)
        File.join(work, ARTIFACTS_DIRECTORY, Checkpoints::Store.digest(root))
      end

      # ONE SPELLING FOR A PATH: expanded, then the real path of its longest
      # EXISTING prefix with the rest appended as written — so a symlinked
      # spelling of a directory and its real one compare equal, and a path
      # that does not exist yet is still judged by where it would land.
      # (The daemon's `Rho.spelled` is this rule; the runner cannot reach
      # the daemon's gem, and the placement memo keys on it.)
      def self.spelled(path)
        expanded = File.expand_path(path)
        existing = expanded
        existing = File.dirname(existing) until (exists = File.exist?(existing)) || existing == File.dirname(existing)
        return expanded unless exists

        File.join(File.realpath(existing), expanded.delete_prefix(existing).delete_prefix("/")).delete_suffix("/")
      end

      # `root` is a PATH, not rho's Home. The runner must load in a process
      # that has no daemon in it, so nothing here may reach for a type from
      # the daemon's gem — the caller resolves its own root and hands it
      # over, with the captures' directory placed (`artifacts_dir_for`).
      def initialize(root:, artifacts_dir:, subdir: nil, directories: [], documents_root: nil,
                     mutation_queue: FileMutationQueue.new, bash_timeout_seconds: 120, processes: nil,
                     checkpoints: nil, checkpoint_resolver: nil)
        @root = resolve_root(File.expand_path(root), subdir)
        @directories = directories.map { |path| File.expand_path(path) }.freeze
        @documents_root = documents_root && File.expand_path(documents_root)
        @artifacts_dir = File.expand_path(artifacts_dir)
        @mutation_queue = mutation_queue
        @bash_timeout_seconds = bash_timeout_seconds
        @processes = processes
        @checkpoints = checkpoints
        @checkpoint_resolver = checkpoint_resolver
        freeze
      end

      def checkpoint_stores(id = nil)
        if @checkpoint_resolver
          @checkpoint_resolver.call(id)
        elsif checkpoints && (id.nil? || checkpoints.id == id)
          [checkpoints]
        else
          []
        end
      end

      # Absolute and `~` paths pass through; a relative path resolves
      # against the execution root.
      def resolve(path)
        File.expand_path(path, root)
      end

      # INSIDE THE ROOT SET: a spelled-prefix test of the resolved path over
      # `[root, *directories]` — `..` and symlinks judged on the spelling
      # they land at. A statement, never a refusal: the port routes on it.
      def in_roots?(path)
        candidate = self.class.spelled(resolve(path))
        [root, *directories].any? do |member|
          spelled = self.class.spelled(member)
          candidate == spelled || candidate.start_with?("#{spelled}/")
        end
      end

      def ensure_artifacts_dir!
        FileUtils.mkdir_p(@artifacts_dir, mode: 0o700)
        @artifacts_dir
      end

      # A CAPTURE IS NAMED BY ITS CONTENT: a finished file renamed beside
      # itself to `<prefix>-<sha256[0,16]><its extension>`, and that path
      # answered. A result names its capture, so a random name would make
      # the same output — a re-run suite over the line cap, an unchanged
      # page's screenshot — read as a new result every time. Written under
      # another name first and renamed (atomic on one filesystem), so a
      # reader never meets a half-written file; identical bytes renamed
      # onto themselves are harmless, across daemons too.
      def keep_capture(path, prefix)
        named = File.join(File.dirname(path),
          "#{prefix}-#{Digest::SHA256.file(path).hexdigest[0, CAPTURE_DIGEST_CHARS]}#{File.extname(path)}")
        File.rename(path, named)
        named
      end

      # Worker-local cancellation, read through the thread. ToolEnv is an
      # immutable value shared by every task; the context belongs to ONE
      # task and is installed on the worker thread that runs it, so it is
      # never retained here and never leaks between jobs.
      def cancelled?
        ExecutionContext.current&.cancelled? || false
      end

      def raise_if_cancelled!
        ExecutionContext.current&.raise_if_cancelled!
      end

      # WHAT THE TOOL IS DOING RIGHT NOW, for a watcher (executor.md
      # "Progress"): the latest tail, handed to the one task's context on
      # this worker thread; the pool posts it under the claim at the
      # kernel's cadence. A tool run outside a task says it to nobody.
      def report_progress(text)
        ExecutionContext.current&.report_progress(text)
      end

      private

      # The one confined thing. A selector that escapes is a caller bug and
      # is refused; a selector is a convenience, never a second root.
      def resolve_root(home_root, subdir)
        return home_root if subdir.nil? || subdir.empty?

        if File.absolute_path?(subdir)
          raise ArgumentError, "cwd must be a relative selector within the bound root, got #{subdir.inspect}"
        end

        resolved = File.expand_path(subdir, home_root)
        prefix = home_root.end_with?("/") ? home_root : "#{home_root}/"
        unless resolved == home_root || resolved.start_with?(prefix)
          raise ArgumentError, "cwd #{subdir.inspect} escapes the bound root"
        end

        resolved
      end
    end
  end
end
