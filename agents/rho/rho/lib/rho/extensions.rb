module Rho
  # THE DAEMON'S HALF OF THE EXTENSION PLANE.
  #
  # rho-runner owns the contract, the registry and the two tool hooks,
  # because a runner on a second machine with no daemon in the process
  # needs all of them. What a DAEMON adds is what only a daemon has: a
  # lifetime to run background work in, and an operator to surface
  # commands to. It adds them by SUBCLASSING the runner's handle, which is
  # the whole mechanism — one `register(api)` written by an extension
  # author works under both hosts and never branches on which one it got.
  #
  # `DEFAULT_EXTENSIONS` enumerates the built-in implementations. The static
  # catalog discovers gem and path descriptions; saved enablement and each
  # descriptor's default select what loads. Disabled plugins remain visible
  # without evaluating their factories or contributing tools and commands.
  module Extensions
    # The set rho ships with, in load order — the order is the order the
    # verbs are listed and the hooks fire. It grows by one line per shipped
    # extension — the runner's standalone `Toolsets.fixed(env:)` makes the
    # same gesture with `Coding` alone.
    module LifecycleHooks
      NAME = "rho.lifecycle_hooks".freeze
      def self.register(_api); end
    end

    DEFAULT_EXTENSIONS = [
      Rho::Runner::Extensions::Coding, Rho::Extensions::Guard, Rho::Runner::Extensions::Checkpoints,
      Rho::Extensions::Processes, Rho::Extensions::Conventions, Rho::Extensions::Until,
      Rho::Extensions::Environment, Rho::Extensions::ConsoleLink, Rho::Extensions::Ops,
      Rho::Extensions::DefaultRunner, Rho::Extensions::Compaction, Rho::Extensions::Todo,
      Rho::Extensions::Schedules,
      Rho::Extensions::Agents, Rho::Extensions::Images, Rho::Extensions::Setup,
      Rho::Extensions::Packages, Rho::Extensions::MemoryReview, LifecycleHooks,
    ].freeze

    DEFAULT_GEMS = ["rho/webui"].freeze
    # Configuration is available before the operator enables polling.
    CONTROL_GEMS = ["rho/ingress-telegram"].freeze
    TOOL_GEMS = ["rho/codemode"].freeze

    # THE SHIPPED SET IS PER MODE. `DEFAULT_EXTENSIONS` stays
    # the FULL set — the e2e preludes swap that constant — and the agent and
    # runner subsets are derived from it at CALL time by two static exclude
    # tables, not by inference: the tool-less extensions (Ops, ConsoleLink,
    # Until, Conventions, Guard, Environment) carry no `serves:` to derive
    # from, and the `serves:` refusal at load is the check that keeps the
    # tables honest. An agent runs no environment tool of its own (Coding);
    # Processes loads in every mode because its VERBS are the person's in
    # every mode — `rho ps`/`rho logs` read a bound runner's table through
    # the call_tool — and it registers its tools only where the
    # host serves the runner address (`Api#serves?`); a runner opens no
    # conversation and holds no member plane (Ops, Compaction, Todo,
    # ConsoleLink, Until, Conventions, DefaultRunner, Agents, Images — an
    # agent-mode rho is exactly the daemon that names remote runners, and
    # keeps it); Guard and Environment serve both.
    AGENT_MODE_EXCLUDES = [Rho::Runner::Extensions::Coding].freeze
    RUNNER_MODE_EXCLUDES = [
      Rho::Extensions::Ops, Rho::Extensions::Compaction, Rho::Extensions::Todo, Rho::Extensions::ConsoleLink,
      Rho::Extensions::Until, Rho::Extensions::Conventions, Rho::Extensions::DefaultRunner, Rho::Extensions::Agents,
      Rho::Extensions::Images,
      Rho::Extensions::Schedules, Rho::Extensions::MemoryReview,
    ].freeze

    # WHAT A TOOL REACHES THE MEMBER PLANE THROUGH: the member client and the
    # adopted workspace, resolved at CALL time by the daemon.
    MemberPlane = Data.define(:client, :workspace_public_id)

    # A background worker owns this member lineage for its whole lifetime.
    # Rotation stays on the same credentials; reconnecting supplies a new handle.
    MemberConnection = Data.define(:user_public_id, :client)

    # Daemon-lifetime infrastructure an extension may close over at
    # register time. `processes` is the daemon's process table, nil under a
    # loader with no daemon (the CLI's, a standalone runner's).
    # `member_plane` is a CALLABLE answering a `MemberPlane` or nil,
    # dereferenced when a tool runs — the daemon's Context is born after
    # the extensions register, so unlike the process table it cannot be
    # bound as a value; nil under a loader with no daemon.
    # Tools pass the ExecutionContext's `workspace_public_id` to keep the
    # kernel-addressed task's scope, including unfollowed nested children.
    # Outside execution, `host_public_id` resolves a followed host's scope;
    # omitting both selects the current default for new work.
    # `serving_tools` is the truthful statement "this process will serve
    # tools" — a host fact of the same kind `processes` is. The CLI runs
    # `register(api)` too, to learn every extension's verbs (`exe/rho`),
    # and passes `false` so an extension whose tools are known only after
    # a connection (rho-mcp: `tools/list` at load)
    # registers its verbs and spawns nothing under `rho status`. Reading
    # `processes.nil?` instead was refused: nil under the CLI AND under a
    # standalone runner, which serves — a correlate, not the property.
    # `checkpoints` is the shadow store's member: nil where the
    # daemon opens none (`checkpoints.enabled: false`, the CLI, a test's
    # host — the extension then registers nothing and announces nothing),
    # else a CALLABLE answering the `Checkpoints::Store` of the moment —
    # `member_plane`'s precedent: the runner root is known at placement,
    # not at boot, and `rho env` may move it, so the daemon opens the
    # store where it builds the runner's env and the extension's hook
    # dereferences it per call.
    # `environments` is the daemon's
    # environment tables as a CALLABLE — `member_plane`'s precedent: the
    # tables are born after the extensions register — dereferenced when
    # the hidden `environment_bind` tool runs; nil under a loader with no
    # daemon, which answers an error the call_tool's caller reads.
    Host = Data.define(:home, :log, :clock, :config, :processes, :member_plane, :serving_tools, :checkpoints,
      :environments) do
      def initialize(member_plane: nil, serving_tools: true, checkpoints: nil, environments: nil, **members)
        super(member_plane: member_plane, serving_tools: serving_tools, checkpoints: checkpoints,
          environments: environments, **members)
      end
    end

    # THE ONE REGISTRAR PER DAEMON: the block that turns an editor's
    # `mcpServers` list — the ACP shape exactly as the door received it —
    # into the SET of tool classes the agent slot serves for one
    # conversation (`Environments::Servers` reads it: `classes`, `report`,
    # `digest`, `close`). rho-mcp registers it at load; the door answers
    # 422 `mcp_unavailable` while nobody has.
    Registrar = Data.define(:extension, :handler)

    # Claimed ONCE per load: the loader builds the handles one at a time,
    # so the second extension to ask meets the first's claim and is
    # refused by name — its load fails, listed as a `Loader::Failure`,
    # and the first stands. (A registrar whose own factory then raised
    # holds the slot for this boot; the failure is listed beside it.)
    class RegistrarSlot
      attr_reader :registrar

      def claim(extension, handler)
        if @registrar
          raise Rho::Runner::Extensions::RegistrationError,
            "#{extension} registers conversation servers; #{@registrar.extension} already did — one registrar per daemon"
        end

        @registrar = Registrar.new(extension: extension, handler: handler)
      end
    end

    # The handle a DAEMON hands an extension: everything the runner's
    # offers, plus the verbs that need a daemon to mean anything.
    class Api < Rho::Runner::Extensions::Api
      AUTHS = %i[bearer none].freeze
      DAEMON_EVENTS = (superclass::DAEMON_EVENTS + %i[conversation_binding member_connection]).freeze

      attr_reader :routes, :commands, :flags, :background_tasks, :daemon_hooks, :conversation_servers, :webui_root, :agents

      def initialize(host:, source:, extension_name:, registrar_slot: RegistrarSlot.new, managed: {}, validate_description: false, **)
        package = managed[source]
        descriptor = host.config.catalog.descriptors[extension_name]
        if descriptor && validate_description
          expected = descriptor.source
          matches = case expected.fetch("kind")
          when "builtin" then source == "<built-in>"
          when "gem" then source == "gem:#{expected.fetch("feature")}"
          when "package" then package&.id == extension_name
          when "path" then source == expected.fetch("path")
          else false
          end
          raise Rho::Runner::Extensions::RegistrationError, "plugin registration does not match its description" unless matches
        elsif validate_description && source != "<built-in>" && source != "<core>"
          raise Rho::Runner::Extensions::RegistrationError, "plugin registration has no static description"
        end
        super(host: host, source: source, extension_name: extension_name,
          configuration: descriptor ? host.config.plugin_configuration(extension_name) : {},
          tool_suffix: package&.revision, **)
        restart_only if descriptor&.restart_only
        @registrar_slot = registrar_slot
        @conversation_servers = nil
        @webui_root = nil
        @routes = []
        @commands = []
        @flags = []
        @background_tasks = []
        @daemon_hooks = []
        @agents = []
      end

      # BOTH SOURCES, REFUSED BY MODE: a daemon admits an agent tool the base handle refuses,
      # and refuses the source its mode cannot serve — naming the extension, the tool, the
      # mode and the ways out. A shipped extension never meets this
      # (`Extensions.defaults_for`); an operator-named one lands as a `Loader::Failure` with
      # the sentence and rides `rho runner`. WHICH ADDRESS THIS DAEMON SERVES, by its mode:
      # full both, agent the agent's alone, runner the runner's alone. An extension whose
      # tools are one address's and whose verbs are every host's asks here before registering
      # a tool the mode would refuse.
      def serves?(source)
        mode = host.config.mode
        !(mode == "agent" && source == :runner) && !(mode == "runner" && source == :agent)
      end

      def register_tool(klass, serves: :runner)
        unless SERVES.include?(serves)
          raise Rho::Runner::Extensions::RegistrationError,
            "#{extension_name} registers #{klass}: serves must be :runner or :agent, not #{serves.inspect}"
        end

        mode = host.config.mode
        if mode == "agent" && serves == :runner
          raise Rho::Runner::Extensions::RegistrationError,
            "#{extension_name} registers `#{klass::NAME}` for the runner; this rho is in mode agent — " \
            "use mode full, or name a runner: `rho run … --runner ID`"
        end
        if mode == "runner" && serves == :agent
          raise Rho::Runner::Extensions::RegistrationError,
            "#{extension_name} registers `#{klass::NAME}` for the agent; this rho is in mode runner — " \
            "use mode full or agent"
        end

        validator = Rho::Runner::Extensions::Tool.validate(klass, extension: extension_name)
        @tools << Rho::Runner::Extensions::Api::Registration.new(klass: klass, serves: serves,
          name: tool_name(klass::NAME), validator: validator)
        self
      end

      # The daemon's collections join the runner's four under the same
      # rule: after commit, a late registration is a FrozenError, not a
      # silent drop.
      def freeze
        @routes.freeze
        @commands.freeze
        @flags.freeze
        @background_tasks.freeze
        @daemon_hooks.freeze
        @agents.freeze
        super
      end

      # Product-owned profiles join the same declaration/removal edge as
      # checkout definitions, and survive a sync without a filesystem root.
      def register_agent(definition)
        return unavailable("named agents") if runner_mode?

        @agents << definition
        self
      end

      # The daemon's `before_agent_start` and
      # `agent_start` (pi types.ts:1282-1283), fired by `Daemon::HostFollowers` in registration order,
      # and the host's end, fired by the daemon
      # when `HostFollowers` forgets a host:
      #   :turn_author (draft, ctx) -> Daemon::HostFollowers::Draft | Daemon::Refusal
      #     fail-CLOSED: a handler that raises refuses the open, a Refusal
      #     it answers is relayed, and the Draft it answers is what the
      #     next handler sees — the lead the turn opens with, and the notes
      #     remembered with the host. The kernel authors round 1 itself.
      #   :turn_follow (run_public_id, notes, ctx) -> gate | nil
      #     fired once the turn's backing run is known; fail-OPEN: a
      #     handler that raises costs that gate, logged.
      #   :host_ended (host_public_id) -> nil
      #     fired once per host this daemon stops following — its terminal,
      #     the kernel's `conversation_ended`, or a 404 — after
      #     the processes its runs started are released; fail-OPEN: a
      #     handler that raises is logged and the next is still told. An
      #     extension holding a child per conversation releases it here.
      #   :conversation_binding (host_public_id) -> Hash | nil
      #     read-only projection of an ingress's existing route binding;
      #     the console displays the source and keeps that conversation read-only.
      #     It is not a second lock or an authorization grant.
      #   member_connection(connection): a MemberConnection on adoption, nil
      #     on loss. Runs on the daemon reactor, serially, before the connection
      #     operation returns; retire the old worker before returning.
      #   configuration_change(config): observes settings already published
      #     locally; failures are logged and the next observer still runs.
      #     Validation that must reject a candidate belongs in register/startup.
      # The runner's events and the lifecycle pair go to the base handle.
      # turn_settled(TurnSettlement, Context): a formal Turn completed,
      # failed or was canceled in Nexus; a failed Turn may still have a held Run.
      # Observers run on the daemon reactor without delaying outcome delivery.
      # Reconnect may replay it; consumers use durable source identity.
      # It does not assert that an external IM delivery succeeded.
      # In RUNNER MODE there is no `HostFollowers` to fire them: they answer the
      # base handle's `unavailable`, logged, never raised.
      def on(event, &handler)
        return super unless DAEMON_EVENTS.include?(event)
        return unavailable("hook #{event}") if runner_mode? && event != :configuration_change
        raise Rho::Runner::Extensions::RegistrationError,
          "on(#{event.inspect}) needs a block" if handler.nil?

        @daemon_hooks << Rho::Runner::Extensions::Hooks::Registration.new(
          event: event, extension: extension_name, handler: handler, owner: resources
        )
        self
      end

      # An HTTP route on the daemon's control surface. `:bearer` demands
      # the local bearer and the admission gate; `:none` is for the doors a
      # caller with no bearer must reach. Handler: (request, ctx).
      def register_route(method, path, auth: :bearer, &handler)
        raise Rho::Runner::Extensions::RegistrationError,
          "register_route(#{method} #{path}) needs a block" if handler.nil?
        unless AUTHS.include?(auth)
          raise Rho::Runner::Extensions::RegistrationError,
            "register_route(#{method} #{path}): auth must be one of #{AUTHS.inspect}, not #{auth.inspect}"
        end

        @routes << Route.new(
          method: method.to_s.upcase, path: path.to_s, auth: auth,
          extension: extension_name, handler: handler, owner: resources
        )
        self
      end

      # The page served at the control surface's root. A failed factory
      # contributes no page; two committed owners refuse the load, as two
      # routes owning the same path refuse daemon boot.
      def register_webui(root:)
        return unavailable("webui") if runner_mode?
        raise Rho::Runner::Extensions::RegistrationError,
          "#{extension_name} already registered a webui" if @webui_root

        root = root.to_s
        raise Rho::Runner::Extensions::RegistrationError,
          "register_webui needs a non-empty root" if root.empty?

        @webui_root = File.expand_path(root)
        self
      end

      # An operator verb, surfaced by `rho` as its own command. `usage` and
      # `description` are what `rho help` prints; `options` are Thor
      # method_option hashes (`{ timeout: { type: :numeric, desc: "…" } }`);
      # `aliases` are spellings that reach the verb without being listed.
      # Handler: (cli, args, options) — it prints through `cli.out`, raises
      # a `Rho::Error` for a refusal (one sentence, exit 1), and its answer
      # is its own: a test or a page reads it, the terminal does not.
      def register_command(name, usage: name.to_s, description: "", long_description: nil,
                           options: {}, aliases: [], &handler)
        raise Rho::Runner::Extensions::RegistrationError,
          "register_command(#{name.inspect}) needs a block" if handler.nil?

        @commands << Command.new(
          name: name.to_s, usage: usage.to_s, description: description.to_s,
          long_description: long_description, options: options.transform_keys(&:to_sym).freeze,
          aliases: aliases.map(&:to_s).freeze, extension: extension_name, handler: handler
        )
        self
      end

      # Flags an extension adds to a CORE verb whose request is a JSON body
      # (today only `run`). `fold` composes the option values into the body:
      # (body, options) -> body. pi has registerFlag + getFlag; ours folds
      # because the CLI and the daemon are two processes.
      def register_flags(command, **options, &fold)
        raise Rho::Runner::Extensions::RegistrationError,
          "register_flags(#{command.inspect}) needs a block" if fold.nil?
        raise Rho::Runner::Extensions::RegistrationError,
          "register_flags(#{command.inspect}) needs at least one option" if options.empty?
        # No `run` in runner mode, so nothing for a flag to land on.
        return unavailable("flags on #{command}") if runner_mode?

        @flags << Flags.new(
          command: command.to_s, options: options.freeze, extension: extension_name, fold: fold
        )
        self
      end

      # Work that lives as long as the daemon does. A 24/7 deployment is
      # the stated one, and an extension that can only respond and never
      # act is half a plane.
      def background(name = extension_name, &handler)
        raise Rho::Runner::Extensions::RegistrationError,
          "background(#{name.inspect}) needs a block" if handler.nil?

        @background_tasks << BackgroundTask.new(
          name: name.to_s, extension: extension_name, handler: handler
        )
        self
      end

      # THE EDITOR'S SERVERS PER CONVERSATION: `{ |anchor, entries| set }` — `entries` the ACP
      # `mcpServers` list as the door received it (stdio `{name, command,
      # args, env: [{name, value}]}`, http `{type, name, url, headers:
      # [...]}`), the block raising ArgumentError with a sentence for a
      # malformed entry (the door's 400) or its own `Rho::Runner::Error`
      # for a set it will not open at all (the door's 503, the shutdown
      # ladder's `Closed`), and answering a SET: `classes` (tool classes
      # as `register_tool` takes them, named `mcp__<name>__<tool>` — the
      # name folded when it must be, so each class also answers
      # `SERVER_KEY`, the report row's `name` it belongs to, which is how
      # the daemon's judgement faults a taken name's ROW), `report`
      # (`{name, state, fault, transport}` per row), `digest` (name +
      # launch + env/header KEYS, never a value), `close` (idempotent).
      # ONE per daemon; the agent slot serves the classes, so a
      # RUNNER-MODE daemon — no agent slot, no conversation — answers
      # `unavailable`, logged, as the hooks do.
      def register_conversation_servers(&handler)
        raise Rho::Runner::Extensions::RegistrationError,
          "register_conversation_servers needs a block" if handler.nil?
        return unavailable("conversation servers") if runner_mode?

        @conversation_servers = @registrar_slot.claim(extension_name, handler)
        self
      end

      # Lifecycle registration lives on the RUNNER's handle now, so an
      # extension can say `on(:shutdown)` under either host; what a daemon
      # adds is that it actually FIRES them (`start_extensions`,
      # `stop_extensions`).

      private

        def runner_mode? = host.config.mode == "runner"
    end

    Route = Data.define(:method, :path, :auth, :extension, :handler, :owner) do
      def initialize(owner: nil, **) = super
    end
    Command = Data.define(:name, :usage, :description, :long_description, :options, :aliases,
      :extension, :handler)
    Flags = Data.define(:command, :options, :extension, :fold)
    BackgroundTask = Data.define(:name, :extension, :handler)
    # A committed extension by name and where it came from — the identity
    # `inventory` lists whether or not it registered a tool.
    Extension = Data.define(:name, :source)
    # Where the operator's extensions are named: the gems their settings
    # list, and the files under RHO_HOME/extensions plus `extension_paths`.
    Sources = Data.define(:gems, :paths, :managed)

    # What a daemon holds after loading: the runner's registry plus the
    # daemon-only registrations, and the failures, which are a product
    # fact rather than a log line — an operator whose extension did not
    # load must be able to SEE that without reading a file.
    # `conversation_servers` is the one committed `Registrar`, or nil.
    Loaded = Data.define(:registry, :extensions, :routes, :commands, :flags, :background_tasks,
      :lifecycle, :daemon_hooks, :conversation_servers, :webui_root, :failures, :agents, :registrations) do
      def initialize(registrations: [], **) = super

      def ok? = failures.empty?

      def command(name) = commands.find { |candidate| candidate.name == name.to_s }

      # The inventory a control surface serves and a UI renders: every
      # committed extension, with names and descriptions, never handlers.
      def inventory
        by_extension = registry.entries.group_by(&:extension)
        extensions.map do |extension|
          tools = Array(by_extension[extension.name]).map do |entry|
            { "name" => entry.name, "description" => entry.description,
              "effect_profile" => entry.effect_profile }
          end
          { "name" => extension.name,
            "source" => extension.source,
            "tools" => tools,
            "commands" => commands.select { |c| c.extension == extension.name }
              .map { |c| { "name" => c.name, "description" => c.description } } }
        end
      end
    end

    module_function

    # The mode's shipped set, read off `DEFAULT_EXTENSIONS` at call time so
    # a prelude-swapped constant flows through (the exclude tables above).
    def defaults_for(mode)
      case mode.to_s
      when "agent" then DEFAULT_EXTENSIONS - AGENT_MODE_EXCLUDES
      when "runner" then DEFAULT_EXTENSIONS - RUNNER_MODE_EXCLUDES
      else DEFAULT_EXTENSIONS
      end
    end

    # One answer for the daemon and the CLI, so the verbs one offers are
    # the verbs the other serves. Sources follow this prepared configuration,
    # including a candidate being applied before any factory is evaluated.
    def sources(home, config, managed: Rho::Packages.new(home: home).sources(plugins: config.plugins))
      managed = managed.select { |source| config.plugin_enabled?(source.id) }
      descriptors = config.catalog.descriptors.values.select { |descriptor| config.plugin_enabled?(descriptor.id) }
      gems = descriptors.filter_map { |descriptor| descriptor.source["feature"] if descriptor.source["kind"] == "gem" }
      paths = descriptors.filter_map { |descriptor| descriptor.source["path"] if descriptor.source["kind"] == "path" }
      Sources.new(gems: gems, paths: paths + managed.map(&:path), managed: managed)
    end

    def selected_builtins(config, extensions = DEFAULT_EXTENSIONS)
      extensions.select do |mod|
        id = Rho::Runner::Extensions::Loader.extension_name_of(mod)
        (!config.catalog.descriptors.key?(id) && !config.catalog.failures.key?(id)) || config.plugin_enabled?(id)
      end
    end

    # `sources` selects gem features and paths; the built-in set is rho's.
    # A test may name narrower sets to prove an extension loads alone.
    def load(host:, extensions: DEFAULT_EXTENSIONS, gems: [], paths: [], log: nil, reuse: [], managed: [])
      registrar = RegistrarSlot.new
      reuse.each do |api|
        entry = api.conversation_servers
        registrar.claim(entry.extension, entry.handler) if entry
      end
      result = Rho::Runner::Extensions::Loader.call(
        builtin: extensions, gems: gems, paths: paths,
        api_class: Api, api_options: { host: host, validate_description: true, registrar_slot: registrar, managed: managed.to_h { |package| [package.path, package] } }, log: log, reuse: reuse
      )
      assemble(result.committed, failures: result.failures, registry: result.registry)
    rescue StandardError, ScriptError
      (result&.committed.to_a - reuse).reverse_each { |api| api.resources.retire }
      raise
    end

    # Only successful owners contribute runtime surfaces. The same assembly
    # serves initial loading and removal of an owner whose startup failed.
    def assemble(registrations, failures: [], registry: nil)
      registry ||= registrations.each_with_object(Rho::Runner::Extensions::Registry.new) do |api, table|
        table.commit(api)
      end
      Loaded.new(
        registry: registry, registrations: registrations,
        extensions: registrations.map { |api| Extension.new(name: api.extension_name, source: api.source) },
        routes: registrations.flat_map(&:routes), commands: registrations.flat_map(&:commands),
        flags: registrations.flat_map(&:flags), background_tasks: registrations.flat_map(&:background_tasks),
        lifecycle: registrations.flat_map(&:lifecycle), daemon_hooks: registrations.flat_map(&:daemon_hooks),
        agents: registered_agents(registrations),
        conversation_servers: registrations.filter_map(&:conversation_servers).first,
        webui_root: webui_root_of(registrations), failures: failures
      )
    end

    def registered_agents(committed)
      definitions = committed.flat_map(&:agents)
      duplicate = definitions.group_by(&:name).find { |_name, rows| rows.length > 1 }
      raise Rho::Runner::Extensions::RegistrationError, "two extensions register agent #{duplicate.first}" if duplicate

      definitions.freeze
    end

    def webui_root_of(committed)
      owners = committed.select(&:webui_root)
      if owners.length > 1
        raise Rho::Runner::Extensions::RegistrationError,
          "multiple webui owners: #{owners.map(&:extension_name).join(", ")} — one page per daemon"
      end

      owners.first&.webui_root
    end
  end
end
