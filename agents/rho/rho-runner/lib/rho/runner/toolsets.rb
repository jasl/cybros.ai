module Rho
  class Runner
    # THE PLACEMENTS: the environment is a
    # per-conversation VALUE the runner resolves at dispatch, and this is
    # where a claimed row is turned into the `Placement` its tools run under.
    #
    # THE HOST RESOLVES, THE RUNNER RECEIVES. The runner never reads the
    # conversation's store record: `resolver` is the host's — the daemon's
    # `Environments`, which memoizes the record, reads the store on the
    # member plane and walks a spawned child's parents (in process); or the
    # received table a host ELSEWHERE filled through the relayed
    # `environment_bind` (a runner-mode daemon) — asked with the row's
    # `conversation_public_id` and its `parent_public_id` (the kernel's own
    # structural fact on the inbox row, so a spawned child resolves by its
    # parent's received binding with no relay in the path), answering an
    # `Environment::Binding` or nil. It runs ON THE WORKER, inside the pool
    # block (`TaskRun#run_handler`): a member-plane GET is ~10-100 ms under
    # the tool's clock and never the reactor's.
    #
    # ONE ENV AND ONE TOOLSET PER ROOT SET, never per conversation: the
    # memo's key is the SPELLED root set (`ToolEnv.spelled` — the real path
    # of the existing prefix, so a symlinked spelling finds its memo), built
    # on first use under one monitor (the root's checkpoint store opens
    # once), and two conversations on one project share one frozen
    # `ToolEnv` object and one toolset. The tools are byte-identical across
    # placements — the same classes over the same registry — and differ in
    # the env alone; only the `Placement` value, which carries the
    # conversation's own record, is minted per claim.
    #
    # PLACEMENT ZERO is the runner's default root (the daemon's `rho env`
    # selection; the harness's `--world`): a standalone loop (no
    # conversation), a binding nobody wrote (a MISS, memoized per loop id
    # so one loop costs one read and the next loop on that conversation
    # reads again — the top-down copy may have landed), a root absent on
    # this host (`environment.unresolved`) or under a protected root
    # (`environment.refused`) — each notice logged once per (conversation,
    # root) — all land there, with no record on the context.
    #
    # THE PORTS RESOLVER rides beside the
    # placements: the daemon's table of editor ports keyed by anchor, a
    # callable the run places on every context so a tool looks its port
    # up PER CALL through `ExecutionContext#port` — never a member of the
    # frozen env.
    #
    # THE EXTRAS ride the AGENT
    # slot's placements alone: the editor's MCP servers, curated by the
    # host into tool classes exactly as `api.register_tool` takes them,
    # keyed by the record's ANCHOR — which a child's copy and a side's
    # fork copy share with their parent, so their turns find the parent's
    # servers with no lookup of their own — and joined onto the placement's
    # toolset over the placement's env, memoized per (env, anchor, set
    # digest): a re-listed set is a new table, an unchanged one the held.
    # `extras` is the host's table: `call(anchor)` answers `[classes,
    # digest]`, `owner_of(name)` the anchor whose editor serves a name (the
    # refusal a call from any other conversation meets), `names` every
    # anchor's (the announced set). nil for a host with none — the runner
    # slot, a standalone runner — and a `Fixed` placement has none.
    class Toolsets
      UNRESOLVED_EVENT = "environment.unresolved".freeze
      REFUSED_EVENT = "environment.refused".freeze
      # A Miss is per loop id; a notice per (conversation, root). Both
      # tables are bounded, the oldest entries dropped first — a lost entry
      # costs one read or one repeated line, never a placement. The
      # extended tables are bounded the same way: a lost entry costs one
      # rebuild over the held classes.
      MISSES_MAX = 256
      NOTICES_MAX = 1024
      EXTENDED_MAX = 256

      # A CONSTANT PLACEMENT (the harness executor, a standalone runner, a
      # test's hand-built toolset): every row lands on the one placement,
      # and nothing is resolved. `env:` alone builds the coding set over it
      # — the standalone answer `Toolset.build(env:)` used to be; `toolset:`
      # carries any toolset as it stands, with or without an env.
      def self.fixed(env: nil, toolset: nil)
        if toolset.nil?
          raise ArgumentError, "a fixed placement needs an env to build the coding set over, or a toolset" if env.nil?

          toolset = Extensions::Loader.call(builtin: [Extensions::Coding]).registry.toolset(env: env)
        end
        Fixed.new(Placement.new(env: env, toolset: toolset, binding: nil))
      end

      class Fixed
        attr_reader :zero

        def initialize(placement)
          @zero = placement
        end

        def for(_task) = @zero

        def names = @zero.toolset.names

        # A fixed placement has no host and no editor: no ports.
        def ports = nil
      end

      # `zero` is the default root's `ToolEnv`; every placement is built from
      # it (its queue, process table and clock) over the registry's toolset.
      # `work_dir` places each root's captures (`ToolEnv.artifacts_dir_for`);
      # `checkpoints` is the host's per-root store opener (`->(root) { Store
      # | nil }`, the daemon's table keyed by real root, opened at first use),
      # nil for a host with no store; `protected_roots` are the host's own
      # (rho's incubation denies), refused here as at the door. `ports` is
      # the host's editor-port lookup (`->(anchor) { FsPort | nil }`),
      # nil for a host with none.
      def initialize(registry:, zero:, resolver:, work_dir:, log: nil, checkpoints: nil, protected_roots: [],
                     ports: nil, extras: nil)
        @registry = registry
        @ports = ports
        @extras = extras
        @zero = Placement.new(env: zero, toolset: registry.toolset(env: zero), binding: nil)
        @resolver = resolver
        @work_dir = work_dir
        @log = log
        @checkpoints = checkpoints
        @protected = protected_roots.map { |root| ToolEnv.spelled(root) }.freeze
        @monitor = Monitor.new
        @placements = { key_for(zero) => [zero, @zero.toolset] }.freeze
        @misses = {}.freeze
        @noticed = {}.freeze
        @extended = {}.freeze
      end

      attr_reader :zero, :ports, :extras

      # The announced set — the registry's names, every placement's, and
      # every anchor's extras beyond them where the host holds any.
      def names = @extras ? (@registry.names | @extras.names) : @registry.names

      # The row's placement, then the anchor's extras joined onto it: the
      # anchor is the RESOLVED record's, whether or not its root placed
      # here (a root absent on this host lands the runner's tools on zero;
      # the editor's servers are the agent slot's and follow the anchor).
      def for(task)
        conversation = task.conversation_public_id
        binding = conversation && resolve(task, conversation)
        placement = binding ? place(binding, conversation) : @zero
        joined(placement, binding&.anchor)
      end

      private

        # No extras on this host: the placement as it stands. Else the
        # table for (env, anchor, digest) — an anchor with no set, and a
        # row with no anchor, share the env's one extended table, which
        # holds no extra and still answers a foreign name as data.
        def joined(placement, anchor)
          return placement if @extras.nil?

          classes, digest = anchor ? @extras.call(anchor) : [[], nil]
          key = classes.empty? ? [placement.env, nil, nil] : [placement.env, anchor, digest]
          toolset = @monitor.synchronize { @extended[key] } || extend_memo(key, placement, classes)
          placement.with(toolset: toolset)
        end

        def extend_memo(key, placement, classes)
          @monitor.synchronize do
            built = @extended[key]
            next built if built

            built = extended(placement, classes)
            @extended = bounded(@extended.merge(key => built), EXTENDED_MAX)
            built
          end
        end

        # The placement's table plus the anchor's classes, each an instance
        # over the placement's env (the registry's own gesture, `tool_for`),
        # under the one `missing` answer.
        def extended(placement, classes)
          env = placement.env
          tools = placement.toolset.to_h.merge(classes.to_h { |klass| [klass::NAME.to_s, tool_over(klass, env)] })
          Toolset.new(tools, ->(name) { foreign(name) })
        end

        def tool_over(klass, env)
          instance = klass.new(env: env)
          Toolset::Tool.new(
            name: klass::NAME.to_s, description: klass::DESCRIPTION, parameters: klass::SCHEMA,
            timeout_ms: Extensions::Tool.timeout_ms(klass), internal_clamp: Extensions::Tool.internal_clamp?(klass),
            effect_profile: klass::EFFECT_PROFILE, handler: ->(args, _context) { instance.call(args) }
          )
        end

        # THE REMOTE-AGENT EDGE: a name another anchor's
        # editor serves is answered as data — the model reads whose it is
        # and never a failed task; a name nobody serves is nil, the run's
        # KeyError as before.
        def foreign(name)
          owner = @extras.owner_of(name)
          return nil if owner.nil?

          Toolset::Tool.new(
            name: name, description: nil, parameters: { "type" => "object" },
            handler: ->(_args, _context) { Result.error("#{name} belongs to conversation #{owner}'s editor and is not offered here") }
          )
        end

        def resolve(task, conversation)
          loop = task.agent_loop_public_id
          return nil if missed?(loop)

          binding = @resolver.call(conversation, task.parent_public_id)
          miss!(loop) if binding.nil?
          binding
        rescue StandardError => error
          # A resolver that RAISED is no Miss: the next claim asks again.
          @log&.warn(UNRESOLVED_EVENT, conversation: conversation, reason: "resolver_failed",
            error_class: error.class.name, detail: error.message)
          nil
        end

        def place(binding, conversation)
          root = ToolEnv.spelled(binding.root)
          unless File.directory?(root)
            notice(UNRESOLVED_EVENT, conversation, binding.root, "root_missing")
            return @zero
          end
          if protected?(root)
            notice(REFUSED_EVENT, conversation, binding.root, "protected_root")
            return @zero
          end

          env, toolset = memo([root, *binding.directories.map { |path| ToolEnv.spelled(path) }])
          Placement.new(env: env, toolset: toolset, binding: binding)
        end

        def protected?(root) = @protected.any? { |member| root == member || root.start_with?("#{member}/") }

        # Zero's key is spelled as a binding's is: the daemon hands its
        # default root as the operator spelled it, and a conversation bound
        # to that directory by its real path is on zero's root set.
        def key_for(env) = [env.root, *env.directories].map { |path| ToolEnv.spelled(path) }

        # Under the monitor: single-flight per root set, so the root's store
        # opens once and two claims of one new root build one env.
        def memo(key)
          @monitor.synchronize do
            built = @placements[key]
            next built if built

            built = build(key)
            @placements = @placements.merge(key => built).freeze
            built
          end
        end

        def build(key)
          root, *directories = key
          zero = @zero.env
          env = ToolEnv.new(
            root: root, directories: directories, documents_root: zero.root,
            artifacts_dir: ToolEnv.artifacts_dir_for(root: root, work_dir: @work_dir),
            mutation_queue: zero.mutation_queue, bash_timeout_seconds: zero.bash_timeout_seconds,
            processes: zero.processes, checkpoints: @checkpoints&.call(root), checkpoint_resolver: zero.checkpoint_resolver
          )
          [env, @registry.toolset(env: env)]
        end

        def missed?(loop) = @monitor.synchronize { @misses.key?(loop) }

        def miss!(loop)
          @monitor.synchronize { @misses = bounded(@misses.merge(loop => true), MISSES_MAX) }
        end

        # Once per (conversation, root): the line says which conversation
        # landed on zero and why; the claim runs there and the result
        # says nothing — the host's placement door carries the notice.
        def notice(event, conversation, root, reason)
          key = [conversation, root]
          first = @monitor.synchronize do
            next false if @noticed.key?(key)

            @noticed = bounded(@noticed.merge(key => true), NOTICES_MAX)
            true
          end
          @log&.warn(event, conversation: conversation, root: root, reason: reason) if first
        end

        def bounded(table, max)
          (table.length > max ? table.drop(table.length - max).to_h : table).freeze
        end
    end
  end
end
