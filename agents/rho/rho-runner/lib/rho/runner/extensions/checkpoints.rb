module Rho
  class Runner
    module Extensions
      # THE CHECKPOINTS EXTENSION — a MODULE on HOST state,
      # Processes' exact shape: a plain module answering `register(api)`,
      # never an instance (the loader names a module by its constant and
      # an instance by nothing), whose state is the host's — `api.host.
      # checkpoints`, a `Checkpoints::Store` the host opened for its one
      # runner root (the harness executor opens one under `--world ROOT
      # --checkpoints DIR` and hands the Store itself; rho's daemon hands a
      # CALLABLE answering the store of the moment — `member_plane`'s
      # precedent: the runner root is known at placement, not at boot, and
      # `rho env` may move it — dereferenced per call). The TOOLS reach the
      # same store through the env (`ToolEnv#checkpoints`), because the
      # registry builds a tool with `env:` alone.
      #
      # REGISTERS ONLY WHERE THERE IS A STORE: on a host with none
      # (`enabled: false`, a standalone runner with no home), nothing
      # registers and nothing is announced — "graceful by construction,
      # never a pretence". The two tools are the runner's person-facing
      # surface: `checkpoint_restore` (write, hidden) and `checkpoints` (read,
      # hidden).
      #
      # THE CAPTURE HOOK — before the FIRST write-kind call of a loop, on
      # the `tool_call` chain, ON A WORKER (the chain runs inside the pool
      # block; the reactor never blocks on a `git add`). WHICH calls: the
      # ANNOUNCED profile, `tool.effect_profile["kind"] == "write"` —
      # `write`, `edit`, `bash` (`world: open`: a read-only `ls` in bash
      # captures once, owned by the caps), rho's `start_process`/`stop_
      # process`, any MCP tool whose mapped profile is write-kind; reads
      # never capture; THE EXTENSION'S OWN TOOLS ARE EXEMPT BY NAME
      # (`checkpoint_restore` captures its undo itself; `checkpoints` is a read)
      # — ONE capture per write-kind call, never two. TWO
      # FLAGS PER LOOP, in memory: `captured` and `correlated`. A transient
      # skip (`timeout`, `git_failed`) is retried on the loop's next
      # write-kind call and rides NO key — the kernel's cache reads the
      # first write row, and a `skipped` there would say "declined" for
      # good while the retry's record stands in the store (K-s3: a keyless
      # row makes the reader ask the truth); only a success or a SIZE cap
      # (final) closes `captured`, and only those ride. The ref is written
      # create-only, so a runner restart that forgets the flags cannot
      # overwrite a loop's first tree: the store answers its record and
      # the hook correlates it. THE MARKS: a
      # path-precise call whose `path` lies OUTSIDE the root still
      # captures the root and the key carries `outside: [path]`; a target
      # inside the root that the excludes ignore (`.env`) is named in
      # `ignored: [paths]` — the record says what a restore cannot reach,
      # never a pretence, and no secret enters a store under the home.
      # THE KEY RIDES the first write-kind result that COMPLETES
      # (`tool_result`, fail-open): `metadata.checkpoint = {hash, store,
      # outside?, ignored?}` or `{skipped, bytes, files}`; if the capturing
      # call raised, the tree and record exist and the key rides the NEXT
      # write-kind result. NO `runner` in the key (K-s1). The hook
      # NEVER raises and never vetoes: a capture that fails logs
      # `checkpoint_skipped` and answers nil ("no opinion") — a task's
      # cancellation alone passes through, as the chain's rule says.
      # WHICH STORE: the CONTEXT'S PLACEMENT'S — a
      # conversation bound to another root runs under an env whose
      # `checkpoints` is that root's store (opened per real root by the
      # host), read off `ExecutionContext.current.tool_env`, so the
      # conversation's own tree is captured and never the daemon's default
      # root's; a context with no placement (a call outside a run, the
      # harness executor) falls to the host's member.
      module Checkpoints
        NAME = "rho.checkpoints".freeze

        TOOLS = [Tools::CheckpointRestore, Tools::Checkpoints].freeze
        # THE RUNNER TOOL A HOST RELAYS A CONVERSATION'S BINDING WITH: rho's `Rho::Extensions::Environment::Tools::Bind`,
        # an HONEST write-kind runner-state write, hidden by name. A string
        # here because rho-runner cannot see rho's constant (rho depends on
        # this gem); rho's own test pins the two spellings equal. Without
        # it every relayed bind would snapshot the runner's default root.
        ENVIRONMENT_BIND = "environment_bind".freeze
        # The extension's own tools and the relayed bind: never captured.
        EXEMPT = [*TOOLS.map { |klass| klass::NAME }, ENVIRONMENT_BIND].freeze
        WRITE_KIND = "write".freeze
        # The path-precise tools' one argument (`write`/`edit`): resolved
        # through the env's rule (absolute and `~` untouched, a relative
        # path against the root).
        PATH_ARGUMENT = "path".freeze
        RESERVED_KEY = "checkpoint".freeze
        SKIPPED_EVENT = "checkpoint_skipped".freeze

        # THE TWO FLAGS PER LOOP, under one mutex (the pool's workers are
        # threads): `key` the value to ride once `captured` is final, and
        # `correlated` once it rode.
        class Flags
          Loop = Data.define(:key, :correlated)
          private_constant :Loop

          def initialize
            @mutex = Mutex.new
            @loops = {}
          end

          # Closed: a success or a final skip stands for this loop.
          def captured?(run_public_id) = @mutex.synchronize { @loops.key?(run_public_id) }

          # Closes the loop with the key to ride; a second closer (two
          # parallel writes of one loop, or a retry after a raise) keeps
          # the first.
          def capture!(run_public_id, key)
            @mutex.synchronize { @loops[run_public_id] ||= Loop.new(key: key, correlated: false) }
            nil
          end

          # The key to ride NOW, once: nil unless captured and not yet
          # correlated. Sets `correlated`.
          def take_key(run_public_id)
            @mutex.synchronize do
              entry = @loops[run_public_id]
              next nil if entry.nil? || entry.correlated

              @loops[run_public_id] = entry.with(correlated: true)
              entry.key
            end
          end
        end

        def self.register(api)
          return unless api.serves?(:runner) && store_of(api)

          member = store_of(api)
          flags = Flags.new
          log = api.log
          TOOLS.each { |klass| api.register_tool(klass) }
          api.on(:tool_call) { |name, arguments, tool| capture(member, flags, name, arguments, tool, log) }
          api.on(:tool_result) { |name, result, tool| correlate(flags, name, result, tool) }
          # The prune: the store's retention, on the host's own
          # startup, under the store's lock and clock; a host whose store
          # opens later (a fresh pairing) prunes at its next boot.
          api.on(:startup) { current(member)&.prune }
          # A candidate starts before publication; prune again after the new
          # environment and retention policy have become the active settings.
          api.on(:configuration_change) { current(member)&.prune }
        end

        # The host's store MEMBER, or nil: no host, or a host whose member
        # is nil, is a host without a store. A Store, or a callable
        # answering one (the daemon's, dereferenced per call by `current`).
        def self.store_of(api) = api.host&.checkpoints

        # The store of the moment: a callable member is asked, a Store is
        # itself; nil when the host has none yet (no root placed, the root
        # under a protected root).
        def self.current(member) = member.respond_to?(:call) ? member.call : member

        # THE CAPTURE'S STORE: the context's placement's when the run placed
        # one (the conversation's root), else the host's member.
        def self.placed_store(member)
          ExecutionContext.current&.tool_env&.checkpoints || current(member)
        end

        # THE CAPTURE (the `tool_call` half): answers nil always — no veto,
        # no rewrite — and records the key to ride on the flags.
        def self.capture(member, flags, name, arguments, tool, log)
          return nil unless captures?(name, tool)

          run_public_id = ExecutionContext.current&.run_public_id
          return nil if run_public_id.nil? || flags.captured?(run_public_id)

          store = placed_store(member)
          return nil if store.nil?

          outside, inside = targets(arguments, store.root)
          outcome = store.capture(run_public_id: run_public_id, outside: outside, ignored: store.ignored(inside))
          flags.capture!(run_public_id, outcome.key) if !outcome.skip? || outcome.final?
          nil
        rescue ExecutionContext::Cancelled
          raise
        rescue StandardError => error
          log&.warn(SKIPPED_EVENT, run_public_id: run_public_id, reason: "hook_failed", error_class: error.class.name,
            detail: error.message)
          nil
        end

        # THE CORRELATION (the `tool_result` half): the key onto the first
        # write-kind result that completes, once per loop.
        def self.correlate(flags, name, result, tool)
          return nil unless captures?(name, tool) && result.is_a?(Result)

          run_public_id = ExecutionContext.current&.run_public_id
          return nil if run_public_id.nil?

          key = flags.take_key(run_public_id)
          return nil if key.nil?

          result.with(metadata: (result.metadata || {}).merge(RESERVED_KEY => key))
        end

        # A write-kind call by the ANNOUNCED profile, not one of ours.
        def self.captures?(name, tool)
          return false if EXEMPT.include?(name.to_s)

          tool.effect_profile&.dig("kind") == WRITE_KIND
        end

        # `[outside, inside]`: the call's own `path`, resolved as the env
        # resolves it — outside the root as the absolute path the key
        # carries, inside as the root-relative path `Store#ignored` checks.
        def self.targets(arguments, root)
          # An MCP tool's `path` is whatever ITS schema admits: only a string names a file.
          path = arguments[PATH_ARGUMENT]
          return [[], []] unless path.is_a?(String) && !path.empty?

          resolved = File.expand_path(path, root)
          prefix = "#{root}/"
          return [[], [resolved.delete_prefix(prefix)]] if resolved.start_with?(prefix)

          resolved == root ? [[], []] : [[resolved], []]
        end
      end
    end
  end
end
