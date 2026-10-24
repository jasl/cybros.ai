require "pathname"

module Rho
  module Env
    # Resolve the execution's captured directory before hooks or handlers start.
    # Placement caches share immutable environments; no conversation lookup is involved.
    class Toolsets
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
      def initialize(registry:, zero:, work_dir:, log: nil, checkpoints: nil, protected_roots: [],
                     ports: nil, extras: nil)
        @registry = registry
        @environment_independent = registry.entries.select { |entry| !Extensions::Tool.environment_required?(entry.klass) }.map(&:name).freeze
        @ports = ports
        @extras = extras
        @zero = Placement.new(env: zero, toolset: registry.toolset(env: zero), binding: nil)
        @work_dir = work_dir
        @log = log
        @checkpoints = checkpoints
        @protected = protected_roots.map { |root| ToolEnv.spelled(root) }.freeze
        @monitor = Monitor.new
        @placements = { key_for(zero) => [zero, @zero.toolset] }.freeze
        @extended = {}.freeze
      end

      attr_reader :zero, :ports, :extras

      # The announced set — the registry's names, every placement's, and
      # every anchor's extras beyond them where the host holds any.
      def names = @extras ? (@registry.names | @extras.names) : @registry.names

      def for(task)
        return @zero if task.executor_context.nil? && @environment_independent.include?(task.tool_name)

        value = task.executor_context&.fetch(Environment::CONTEXT_KEY, nil)
        binding = Environment::Binding.parse(value)
        raise ArgumentError, "missing or invalid rho.environment executor context" unless binding
        unless [binding.root, *binding.directories].all? { |path| Pathname.new(path).absolute? }
          raise ArgumentError, "rho.environment requires absolute directories: #{binding.root.inspect}"
        end

        joined(place(binding), binding.anchor)
      end

      private

        # No extras on this host: the placement as it stands. Else the
        # table for (env, anchor, digest) — an anchor with no set, and a
        # row with no anchor, share the env's one extended table, which
        # holds no extra and still answers a foreign name as data.
        def joined(placement, anchor)
          return placement if @extras.nil?

          entries, digest = anchor ? @extras.call(anchor) : [{}, nil]
          key = entries.empty? ? [placement.env, nil, nil] : [placement.env, anchor, digest]
          toolset = @monitor.synchronize { @extended[key] } || extend_memo(key, placement, entries)
          placement.with(toolset: toolset)
        end

        def extend_memo(key, placement, entries)
          @monitor.synchronize do
            built = @extended[key]
            next built if built

            built = extended(placement, entries)
            @extended = bounded(@extended.merge(key => built), EXTENDED_MAX)
            built
          end
        end

        # The placement's table plus the anchor's entries, each an instance
        # over the placement's env (the registry's own gesture, `tool_for`),
        # under the one `missing` answer.
        def extended(placement, entries)
          env = placement.env
          tools = placement.toolset.to_h.merge(entries.transform_values { |entry| tool_over(entry, env) })
          Toolset.new(tools, ->(name) { foreign(name) })
        end

        def tool_over(entry, env)
          instance = entry.klass.new(env: env)
          Toolset::Tool.new(
            name: entry.name, description: entry.description, parameters: entry.schema, validator: entry.validator,
            timeout_ms: entry.timeout_ms, internal_clamp: Extensions::Tool.internal_clamp?(entry.klass),
            effect_profile: entry.effect_profile, admission: entry.admission, handler: ->(args, _context) { instance.call(args) }
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

        def place(binding)
          paths = [binding.root, *binding.directories].map { |path| ToolEnv.spelled(path) }
          paths.each do |path|
            unless File.directory?(path) && File.readable?(path) && File.executable?(path)
              raise ArgumentError, "rho.environment directory unavailable: #{path.inspect}"
            end
            raise ArgumentError, "rho.environment protected directory: #{path.inspect}" if protected?(path)
          end

          env, toolset = memo(paths)
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

        def bounded(table, max)
          (table.length > max ? table.drop(table.length - max).to_h : table).freeze
        end
    end
  end
end
