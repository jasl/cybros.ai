require "cybros_agent"
require "ipaddr"
require "openssl"
require "securerandom"
require "socket"
require "time"
require_relative "daemon/ceremony"
require_relative "daemon/context"
require_relative "daemon/connections"
require_relative "daemon/executor_plane"
require_relative "daemon/lineage"
require_relative "daemon/loops"
require_relative "daemon/maintenance"
require_relative "daemon/refusal"
require_relative "daemon/routes"
require_relative "daemon/runners"
require_relative "daemon/settings"
require_relative "daemon/wire"
require_relative "environments"

module Rho
  # One daemon per RHO_HOME: claim the home,
  # load the extensions, serve the control surface, and stop keeping the home
  # lock until every writer is dead. It is the ONLY lock: identity roots live inside it.
  #
  # THREE MODES ON ONE EXECUTABLE, a boot fact read from the
  # settings before any connection exists: `full` pairs one combined grant
  # and runs two loops — the runner address's (this machine's tools, the
  # environment document) and the agent address's own; `agent` runs the
  # agent's loop alone and names a runner (`rho do --runner`, the `runner`
  # setting); `runner` serves tools alone and constructs NO member plane —
  # no `Loops`, no `HostStore`, no page, no `/profile` read, no member
  # socket, no Ensure-Workspace — pinned by a zero-member-request boot test.
  class Daemon
    # 3: the console handoff routes; `control_version` is how a page says
    # "I need those".
    ANNOUNCEMENT_VERSION = 3
    LOOPBACK = "127.0.0.1".freeze
    # A wider bind is an operator assertion, never a detection: exactly one per boot, remembered by nobody.
    TRANSPORT_ASSERTIONS = %i[external_encryption plaintext].freeze
    WILDCARD_BINDS = %w[0.0.0.0 ::].freeze
    # Named so nobody mistakes it for a kernel credential: it authorizes
    # this daemon's own surface and no Nexus request whatsoever.
    LOCAL_BEARER_PREFIX = "rho-local-v1-".freeze
    STOP_CONTROL_DRAIN_DEADLINE = 5

    attr_reader :home, :endpoint, :bearer
    # The collaborators by name; none of them hands out the daemon itself.
    # `loops` is nil in runner mode.
    attr_reader :host, :context, :routes, :lineage, :wire, :ceremony, :maintenance, :loops, :executor_plane

    def self.boot(home:, bind: LOOPBACK, port: 0, on_phase: nil, clock: -> { Time.now },
      sleeper: ->(seconds) { sleep(seconds) },
      server_class: ControlServer::DEFAULT_SERVER, device_flow: nil, api_transport: nil,
      display_name: nil, renewal_interval: Renewal::DEFAULT_INTERVAL, webui_root: nil,
      transport_assertion: nil, log: nil, config: nil, realtime_factory: nil,
      extensions: nil)
      config ||= Config.load(home.settings_path)
      bind = config.bind || bind
      verify_bind(bind, transport_assertion: transport_assertion,
        access_passphrase: config.access_passphrase)

      new(home: home, bind: bind, port: port, on_phase: on_phase, clock: clock, sleeper: sleeper,
        server_class: server_class, device_flow: device_flow, api_transport: api_transport,
        display_name: display_name, renewal_interval: renewal_interval,
        webui_root: webui_root, transport_assertion: transport_assertion, log: log,
        config: config, realtime_factory: realtime_factory, extensions: extensions).send(:start)
    end

    # A wider bind needs both: the assertion says nobody can read the
    # traffic, the passphrase says not everyone reaching the port is the
    # operator — a reverse proxy satisfies only the first.
    def self.verify_bind(bind, transport_assertion: nil, access_passphrase: nil)
      address = begin
        IPAddr.new(bind)
      rescue IPAddr::InvalidAddressError
        raise ConfigurationError, "#{bind.inspect} is not an IP address"
      end
      return if address.loopback?

      unless TRANSPORT_ASSERTIONS.include?(transport_assertion)
        raise ConfigurationError,
          "#{bind} is not loopback. A wider bind needs one explicit transport assertion per boot: " \
          "--expect-external-encryption if TLS or a VPN fronts this socket, or " \
          "--unsafe-plaintext to acknowledge bare plaintext. Neither is remembered between boots."
      end
      return unless access_passphrase.to_s.empty?

      raise ConfigurationError,
        "#{bind} is not loopback and no access_passphrase is set. A wider bind hands this " \
        "daemon's control surface to everyone who can reach the port. Set access_passphrase " \
        "in #{File.basename("settings.json")} or RHO_ACCESS_PASSPHRASE (at least " \
        "#{AccessLock::MIN_LENGTH} characters), or bind loopback."
    end

    def initialize(home:, bind:, port:, on_phase:, clock:, sleeper: ->(seconds) { sleep(seconds) },
      server_class: ControlServer::DEFAULT_SERVER, device_flow: nil, api_transport: nil, display_name: nil,
      renewal_interval: Renewal::DEFAULT_INTERVAL, webui_root: nil, transport_assertion: nil,
      log: nil, config: nil, realtime_factory: nil, extensions: nil)
      @home = home
      @log = log
      @config = Config::Current.new(config || Config.from_hash({}))
      # The mode's shipped set, or the narrower one a test names to prove an
      # extension loads alone.
      @extensions = extensions || Extensions.defaults_for(@config.mode)
      @access_lock = AccessLock.build(@config.access_passphrase)
      @transport_assertion = transport_assertion
      @renewal_interval = renewal_interval
      # Explicit argument or settings; the plugin supplies the default after loading.
      @webui_root = webui_root || config.webui_root
      @device_flow = device_flow
      @wire = Wire.new(base_url: home.base_url, api_transport: api_transport)
      @display_name = display_name || Rho.default_display_name
      @bind = bind
      @port = port
      @on_phase = on_phase
      @clock = clock
      # The waits a verb holds a terminal on (a turn's materialization) and
      # the follower's poll, one seam beside the clock: a test drives both.
      @sleeper = sleeper
      @server_class = server_class
      # One ActionCable connection per credential lineage, minted pure: the
      # first byte crosses when a followed feed subscribes.
      @lineage = Lineage.new(
        clock: clock, realtime_factory: realtime_factory || ->(credential) { build_realtime(credential) }
      )
      @announcement = Rho::StateFile.new(home.announcement_path)
      # THE PROCESS LIFE: announced in the
      # runner address's opaque environment document and answered by the
      # hidden `environment_bind` tool — the key a host elsewhere
      # re-asserts a conversation's root set on. Constant across `rho env`.
      @booted_at = @clock.call.utc.iso8601
    end

    def phase = @lineage.phase

    def connection = @lineage.connection

    def identity = @lineage.identity

    def mode = @config.mode

    def runner_mode? = @config.mode == "runner"

    # A console hint on an api_only daemon, or one with no build, is a lie.
    def page? = !@webui.nil?

    # Opened lazily after `prepare` made `log/` exist, and never in a test
    # that did not ask for one.
    def log
      @log ||= Rho::Log.to_file(@home.log_path, clock: @clock)
    end

    def running? = @lineage.phase != :stopped

    # Drain, then disappear: the announcement says `draining` before the
    # listener closes, and extensions stop before the runner's answer wait
    # so a table close kills process groups first. The home lock goes last.
    def stop
      return self unless running?

      begin_stop
      log.info("daemon.stopping", phase: @lineage.phase)
      transition(:draining)
      stop_extensions
      # The editor's servers per conversation close beside the extensions'
      # own tables.
      @environments.shutdown
      revoke_grants
      retire(@lineage.retire_runs, wait: true)
      @server.stop
      @ceremony.drain_poller
      @maintenance.stop
      @announcement.delete
      @lock.release
      transition(:stopped)
      log.info("daemon.stopped")
      self
    end

    def inspect = "#<Rho::Daemon endpoint=#{@endpoint.inspect} phase=#{@lineage.phase}>"
    alias_method :to_s, :inspect

    private

      # Claim home → host → extensions → the facade and the collaborators →
      # server → the one maintenance worker → resume → announce → extensions
      # start.
      def start
        @home.prepare
        claim_home
        log.info("daemon.boot", version: VERSION, home: @home.root,
          nexus: @home.base_url, pid: Process.pid)
        @bearer = "#{LOCAL_BEARER_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
        # `member_plane` closes over a Context that does not exist yet and
        # is dereferenced when a tool runs (Extensions::Host); `checkpoints`
        # likewise closes over the placement store of the moment — nil
        # where no store can open (`checkpoints_member`), so the extension
        # registers nothing then; `environments` over the tables built
        # with the collaborators.
        @host = Extensions::Host.new(home: @home, log: log, clock: @clock, config: @config,
          processes: process_registry, member_plane: ->(**options) { member_plane_handle(**options) },
          checkpoints: checkpoints_member, environments: -> { @environments })
        @loaded = load_extensions
        @webui = webui
        refuse_serving_nothing
        build_collaborators
        @server = ControlServer.new(
          bind: @bind, port: @port, routes: @routes.table, static_root: @webui,
          server_class: @server_class
        )
        # An IPv6 literal needs brackets to be a URL at all.
        host = IPAddr.new(@bind).ipv6? ? "[#{@bind}]" : @bind
        @endpoint = "http://#{host}:#{@server.port}"
        @server.run
        log.info("daemon.listening", endpoint: @endpoint,
          transport: @transport_assertion || "loopback")
        transition(:disconnected)
        @maintenance.start
        @ceremony.resume_stored
        @lineage.finish_bootstrap
        announce
        start_extensions
        self
      rescue StandardError => error
        log.error("daemon.boot_failed", error: error)
        @server&.stop
        @maintenance&.stop
        @lock&.release
        raise
      end

      # First thing, before a port is bound or a byte is written.
      def claim_home
        @lock = Lock.acquire(@home.boot_lock_path)
      rescue Lock::AlreadyHeld
        raise AlreadyRunning, "a daemon is already running for #{@home.root}#{running_hint}"
      end

      # Advisory only: the announcement may be a killed daemon's, so it
      # names the other instance and is never consulted for exclusion.
      def running_hint
        document = @announcement.read
        return "" if document.nil?

        " (announced pid #{document["pid"]}, endpoint #{document["endpoint"]})"
      rescue StandardError
        ""
      end

      # FULL MODE WITH AN EMPTY RUNNER REGISTRY REFUSES TO BOOT: one page per mode, no serving-nothing row.
      def refuse_serving_nothing
        return unless @config.mode == "full" && @loaded.registry.serving(:runner).entries.empty?

        raise ConfigurationError,
          "mode full serves tools on this machine and none loaded — set mode: agent, or restore the extensions"
      end

      # The facade resolves what is built after it at call time; the
      # lineage edges stay here as callbacks because what they do outside
      # the monitor needs the server. THE MEMBER PLANE IS NOT BUILT IN RUNNER
      # MODE: no `Loops` (and no `HostStore` behind it), no member
      # credential for the facade, no Ensure-Workspace — the executor plane
      # is what every mode shares.
      def build_collaborators
        @settings = Settings.new(home: @home, config: @config, apply: method(:apply_settings).to_proc,
          validate: method(:validate_settings).to_proc)
        @context = Context.new(
          host: @host, bearer: @bearer, page: page?, lineage: @lineage, wire: @wire, loaded: @loaded,
          environment_store: EnvironmentStore.new(@home.environment_path),
          endpoint: -> { @endpoint },
          member_credential: (->(about) { member_credential_for(about) } unless runner_mode?),
          executor_credential: ->(about) { executor_credential_for(about) },
          tool_env: -> { @environments.zero.env }, loops: -> { @loops },
          spawn: ->(&work) { @server.spawn(&work) }, repointed: -> { repoint_zero },
          environments: -> { @environments },
          announcements: -> { @executor_plane.announced }, settings: @settings
        )
        # THE ENVIRONMENT TABLES: one instance the
        # daemon owns — the record memo and store client, the assertions,
        # the received table, the placements and their stores, the editor
        # ports and servers — handed to the Host (the hidden tool), the
        # runner's resolver and `Loops`. The servers table judges
        # names against the WHOLE registry and, past a moved set, has the
        # agent slot announce the union again (`reannounce`).
        @environments = Environments.new(
          home: @home, config: @config, registry: @loaded.registry.serving(:runner), log: log, clock: @clock,
          booted_at: @booted_at, default_root: -> { @context.environment.root },
          member_plane: ->(**options) { member_plane_handle(**options) }, own_runner: ->(public_id) { @context.own_runner?(public_id) },
          learn_runner: ->(document) { @loops&.learn_runner(document) },
          spawn: ->(&work) { @server.spawn(&work) }, processes: @host.processes,
          checkpoints: !@host.checkpoints.nil?, registrar: @loaded.conversation_servers, served: @loaded.registry,
          servers_changed: -> { reannounce(:agent_runner) }
        )
        @executor_plane = ExecutorPlane.new(wire: @wire, lineage: @lineage, context: @context, log: log,
          booted_at: @booted_at)
        unless runner_mode?
          @loops = Loops.new(
            lineage: @lineage, home: @home, config: @config, wire: @wire, loaded: @loaded, log: log,
            context: @context, clock: @clock, sleeper: @sleeper, environments: @environments,
            on_host_ended: ->(host) { host_ended(host) }
          )
        end
        @maintenance = Maintenance.new(
          lineage: @lineage, home: @home, wire: @wire, clock: @clock, interval: @renewal_interval,
          log: log, announce: -> { announce }, lose: ->(**edge) { lose_authority(**edge) },
          lose_runner: ->(**edge) { lose_runner_authority(**edge) }, mode: @config.mode,
          workspace: @config.workspace, workspace_selection: -> { @config.workspace_selection(@home) },
          member_credential: ->(about) { member_credential_for(about) },
          on_workspace_adopted: ->(about, credential, public_id) { place_runners(about, credential, public_id) },
          spawn: ->(&work) { @server.spawn(&work) },
          sweep: -> { sweep }
        )
        @ceremony = Ceremony.new(
          lineage: @lineage, home: @home, device_flow: @device_flow, wire: @wire, clock: @clock,
          display_name: @display_name, log: log, maintenance: @maintenance, mode: @config.mode,
          announce: -> { announce }, adopt: ->(**facts) { adopt_connection(**facts) },
          adopt_runner: ->(**facts) { adopt_runner(**facts) },
          settle: ->(adoption, phase) { settle(adoption, phase) },
          lose: ->(**edge) { lose_authority(**edge) }, lose_runner: ->(**edge) { lose_runner_authority(**edge) },
          transition: ->(phase) { transition(phase) }
        )
        @routes = Routes.new(routes: core_routes + @loaded.routes, context: @context,
          lineage: @lineage, bearer: @bearer)
      end

      # THE CONVERSATION ENDED HERE: a
      # host this daemon stops following — its terminal, a 404, a handoff
      # away — releases the processes its loops started, and then every
      # `:host_ended` subscriber is told the host's public id, in
      # registration order, fail-OPEN: an extension holding a child per
      # conversation lets it go here, and one that raises costs nothing
      # but its own log line — not the next subscriber, and never the
      # release, which ran first. A runner-mode daemon builds no `Loops`
      # and fires none of this (the registration answered `unavailable`).
      # THE EDITOR'S SERVERS GO WITH THE HOST: the tables
      # close and drop the anchor's set — the agent slot re-announced by
      # the tables' own edge — and the union is declared again on the
      # reactor, its digest gate deciding whether the profile moves.
      def host_ended(host)
        @host.processes&.release(host.public_id)
        servers_dropped = @environments.host_ended(host.public_id)
        @server.spawn { @loops&.declare_union } if servers_dropped
      ensure
        @loaded.daemon_hooks.each do |hook|
          next unless hook.event == :host_ended

          hook.handler.call(host.public_id)
        rescue StandardError => error
          log.warn("host_ended_hook_failed", extension: hook.extension, host: host.public_id,
            error_class: error.class.name)
        end
      end

      # An incomplete or absent build costs the daemon its page, never its
      # control surface; a runner-mode daemon serves no page at all.
      def webui
        return nil if @config.api_only || runner_mode?
        root = @webui_root || @loaded.webui_root
        return nil unless root && StaticFiles.available?(root)

        StaticFiles.new(root: root)
      end

      def locked? = !@access_lock.nil?

      # Core routes go through the door every extension uses, so the table
      # has one owner per [method, path].
      def core_routes
        api = Extensions::Api.new(extension_name: "rho", source: "<core>", log: log, host: @host)
        # Unauthenticated: a probe that needed a credential could not tell
        # "not ready" from "not authorized".
        api.register_route("GET", "/healthz", auth: :none) { |_request, _ctx| [200, health] }
        api.register_route("POST", "/unlock", auth: :none) { |request, _ctx| unlock(request) }
        api.register_route("GET", "/status") { |_request, _ctx| [200, status] }
        api.register_route("POST", "/device/start") { |_request, _ctx| @ceremony.start }
        api.register_route("POST", "/device/cancel") { |_request, _ctx| @ceremony.cancel }
        api.register_route("POST", "/disconnect") do |request, _ctx|
          @ceremony.disconnect(runner_only: ControlServer.json_body(request)["runner"] == true)
        end
        @loops&.register(api)
        api.freeze.routes
      end

      # Passphrase in, bearer out. The body is read before the
      # attempt so the throttle decision is one section inside AccessLock.
      def unlock(request)
        unless locked?
          return Refusal.new(status: 409, code: "not_locked", message: "This daemon has no access passphrase")
        end

        body = ControlServer.json_body(request)
        attempt = @access_lock.attempt(body["passphrase"])
        if attempt.accepted?
          @log&.info("unlock_succeeded")
          return [200, { bearer: @bearer, version: VERSION }]
        end

        if attempt.throttled?
          seconds = attempt.retry_after_seconds
          return Refusal.new(status: 429, code: "locked_out",
            message: "Too many failed attempts; retry in #{seconds}s",
            extra: { retry_after_seconds: seconds })
        end

        # Nothing about the passphrase itself, and no timing to read.
        @log&.warn("unlock_rejected")
        Refusal.new(status: 401, code: "invalid_passphrase", message: "Wrong passphrase")
      end

      # THE DEFAULT ROOT MOVED (`rho env`): placement zero is rebuilt — a new env, toolset and
      # store on the new root; an in-flight call keeps the env it was built
      # on, and a claim resolves its placement on the worker — and the
      # runner address announces the root's document again. The runner
      # itself, its meters, sockets and rows stand: nothing is rebuilt.
      def repoint_zero
        @environments.rebuild_zero
        reannounce(:runner)
      end

      # THE NAMED ANNOUNCE EDGE: the slot's document written again
      # under its own credential, on the reactor, for a slot that is
      # placed; a slot not placed announces at its placement.
      def reannounce(slot)
        about = @lineage.credentials
        return if about.nil? || @lineage.runner(slot).nil?

        credential = slot_credential_for(about, slot)
        return if credential.nil?

        @server.spawn { announce_slot(credential, slot) }
      end

      # ONCE PER MAINTENANCE CYCLE, after Ensure-Workspace: the side sweep
      # and the re-assertion of every conversation bound to a runner
      # elsewhere — a runner restarted with no prompt pending is
      # told again within a cycle.
      def sweep
        return if @loops.nil?

        @loops.sweep_sides(@clock.call)
        @environments.reassert_stale(@loops.host_bindings)
      end

      # The workspace-adopted edge (full and agent mode): the mode's loops,
      # then what the lineage follows and declares beside them. The member
      # credential reaches `readopt` and the declaration, which are the
      # member plane's — once, whatever the slot count.
      def place_runners(about, credential, workspace_public_id)
        slots = @config.mode == "full" ? Lineage::SLOTS : [:agent_runner]
        slots.each { |slot| mount_runner(about, slot) }
        @server.spawn do
          @loops.readopt(nil, workspace_public_id, credential_provider: about.method(:member_credential).to_proc)
        end
        @server.spawn { @loops.declare_configuration(credential) }
      end

      # THE STORE'S MEMBER, decided at boot: nil under
      # `checkpoints.enabled: false` and nil when the WORK root the runner
      # will be placed on — the stated `tools_root`, else the home's work
      # root every default runner root sits under — lies inside a
      # protected root (the program's own checkout, the runner gem's, the
      # install prefix: trees the incubation rules refuse to edit and this
      # store refuses to capture), so the extension registers nothing and
      # announces nothing there, "graceful by construction"; else a
      # callable answering THE CONTEXT'S PLACEMENT STORE —
      # the conversation's own root, bound on the worker before the chain
      # runs — and zero's outside a call (the `:startup` prune). The roots
      # a root is tested against are `Rho.protected_roots` — the home's
      # members, never its work root, so the default install opens a store.
      def checkpoints_member
        return nil unless @config.checkpoints.fetch("enabled")

        candidate = Rho.spelled(@config.tools_root || @home.work_root)
        return nil if Rho.protected_roots(@home).any? { |root| Rho.under?(candidate, root) }

        -> { Rho::Runner::ExecutionContext.current&.tool_env&.checkpoints || @environments.zero_checkpoints }
      end

      # Pure: the first network operation happens when a followed feed subscribes.
      def build_realtime(credential)
        endpoint = CybrosAgent::Realtime::Endpoint.new(base_url: @home.base_url, credential: credential)
        CybrosAgent::Realtime::Client.new(endpoint: endpoint)
      end

      # THE SESSION ENDS WITH THE DAEMON: a clean
      # stop re-declares the constant list before the listener closes, so
      # no grant stands on the profile past this boot; a daemon that DIES
      # leaves its grants there until the next boot's declaration — the
      # accepted window. Best effort: no plane, a refusal, an error, the
      # deadline — each is one log line, never a stop that hangs or raises.
      # ON THE REACTOR, waited for: the declaring gate is a fiber gate
      # (`Loops#initialize`) and `stop` runs on the caller's thread, so the
      # write is spawned where every other declaration runs and this
      # thread waits on the bounded queue `cleanup_runs` waits on.
      def revoke_grants
        return if @loops.nil? || @loops.grants.empty?

        count = @loops.grants.length
        _workspace, about = @lineage.member_plane_snapshot
        credential = about && member_credential_for(about)
        if credential.nil?
          log.warn("grants.revoke_failed", count: count, code: "member_plane_unavailable")
          return
        end

        completed = Thread::Queue.new
        @server.spawn do
          @loops.revoke_grants(credential)
        rescue StandardError => error
          log.warn("grants.revoke_failed", count: count, code: error.class.name,
            error: CybrosAgent::Redaction.call(error.message))
        ensure
          completed.push(true)
        end
        completed.pop(timeout: STOP_CONTROL_DRAIN_DEADLINE) ||
          log.warn("grants.revoke_failed", count: count, code: "stop_deadline")
      rescue StandardError => error
        log.warn("grants.revoke_failed", count: @loops.grants.length, code: error.class.name,
          error: CybrosAgent::Redaction.call(error.message))
      end

      # Started after the announcement so a task can call this daemon's own
      # surface; one task's failure is its own.
      def start_extensions
        @loaded.lifecycle.select { |hook| hook.event == :startup }.each do |hook|
          notify_extension(hook.extension, "startup") { hook.handler.call }
        end
        @loaded.background_tasks.each do |task|
          @server.spawn do
            notify_extension(task.extension, "background:#{task.name}") { task.handler.call }
          end
        end
      end

      # Shutdown runs before anything drains, in reverse registration order,
      # so a task holding a browser can close it while the reactor turns.
      def stop_extensions
        @loaded.lifecycle.select { |hook| hook.event == :shutdown }.reverse_each do |hook|
          notify_extension(hook.extension, "shutdown") { hook.handler.call }
        end
      end

      def notify_extension(extension, what)
        yield
      rescue StandardError => error
        log&.warn("extension_task_failed", extension: extension, detail: what,
          error_class: error.class.name)
        nil
      end

      # Loaded once per daemon; a failure rides `/runner` as a product fact.
      def load_extensions
        sources = Rho::Extensions.sources(@home, @config)
        Rho::Extensions.load(
          host: @host, extensions: @extensions, gems: sources.gems, paths: sources.paths, log: log
        ).tap do |loaded|
          loaded.failures.each do |failure|
            log.warn("extension_unavailable", source: failure.source,
              error_class: failure.error_class, detail: failure.message)
          end
        end
      end

      # Under RHO_HOME, never the project: a log growing inside a watched
      # tree is a rebuild loop, and `artifacts/` in the project pollutes
      # every `git status` the model runs.
      # Whose conversation a loop is reaches the table on every call, from
      # the inbox row the kernel wrote (item P; `conversation_public_id`),
      # in every mode — the daemon resolves nothing.
      # The table's watcher channel rides along: its pump
      # posts each row's output under the row's host through the RUNNER
      # slot of the moment — none placed (agent mode: never a binding),
      # nothing posted — at the kernel's cadence. `RHO_PROGRESS_INTERVAL_MS`
      # is a HARNESS KNOB alone: the e2e journey proving the kernel's
      # per-key bound posts faster than the kernel admits, so the drop is
      # the kernel's and observable; a person never sets it.
      def process_registry
        Rho::Processes::Registry.new(
          log_dir: File.join(@home.log_root, "processes"),
          state_file: Rho::StateFile.new(File.join(@home.tmp_root, "processes.json")),
          log: log,
          progress: Rho::Processes::Pump.new(
            post: ->(frame) { post_process_output(frame) }, log: log, interval_ms: progress_interval_ms
          )
        )
      end

      def progress_interval_ms
        Integer(ENV.fetch("RHO_PROGRESS_INTERVAL_MS", Rho::Runner::Progress::MIN_INTERVAL_MS))
      end

      # The runner slot of the moment posts; a daemon with none placed
      # answers false and the pump drops the frame silently — an
      # agent-mode rho owns no process the kernel would bind it to.
      def post_process_output(frame)
        runner = @lineage.runner(:runner)
        return false if runner.nil?

        runner.report_progress(frame)
        true
      end

      # Status only projects memory; a stale read wakes the one maintenance
      # worker rather than probing on the request. The mode rides it, and
      # LOCAL truth about this daemon's own runner slot —
      # never kernel presence, which a self-read would only stamp.
      def status
        document = @lineage.status_document.merge(mode: @config.mode, runner: runner_facts)
        # THE INSTANCE beside the identity: the home's own
        # per-install part of every identifier the daemon presents, read
        # off the home so the status names the same install `rho status`
        # prints; a lineage that has no identity yet names none.
        if document[:identity]
          document = document.merge(identity: document[:identity].merge(instance_id: @home.instance_id).compact)
        end
        # THE DEFAULT MODEL'S ADAPTATION ROW: the row
        # this boot declares under and its source; a runner declares none.
        document = document.merge(adaptations: @loops.adaptations.facts) unless runner_mode?
        # THE PROFILE'S MODELS as the kernel answered the last declaration —
        # rho's own and the fallback a declined step re-runs on; absent
        # until one landed (a runner never declares).
        models = @loops&.declared_models
        document = document.merge(profile: models) if models
        # A runner adopts no workspace: the block would be a pending that
        # never settles.
        document = document.except(:workspace) if runner_mode?
        @lineage.request_probe
        document
      end

      # `nil` while no runner slot is placed; the identity says whether one
      # was ever registered. `selected` is the settings' `runner` as the
      # file says NOW (`rho runners use` writes it while the daemon runs).
      # `swept` and `nudged` are the one runner's own — nothing rebuilds it,
      # so nothing is carried. They ride together because
      # the PAIR is the diagnosis — a rising `swept` beside `nudged: 0` is
      # work carried by polling with the latency path broken.
      def runner_facts
        facts = { selected: selected_runner }.compact
        runner = @lineage.runner(:runner)
        return facts if runner.nil?

        snapshot = runner.snapshot
        facts.merge(
          running: snapshot.running, tools: snapshot.tools.length, swept: snapshot.swept, nudged: snapshot.nudged,
          in_flight: snapshot.in_flight, socket: @lineage.executor_realtime(:runner)&.connected? || false
        )
      end

      def selected_runner
        @home.settings_runner
      rescue ConfigurationError
        nil
      end

      # `locked` is what an un-credentialed page needs to decide what to
      # offer; the home path stays out because on a wider bind it would
      # hand an unauthenticated peer a username.
      def health
        {
          status: "ok",
          state: @lineage.phase.to_s,
          version: VERSION,
          control_version: ANNOUNCEMENT_VERSION,
          locked: locked?,
        }
      end

      # Five threads write the announcement; the facts are one lineage
      # snapshot and a writer never regresses this process's newer one.
      def announce
        facts = @lineage.announcement_facts
        return if facts.state == "stopped"

        document = announcement_document(facts)
        @announcement.with_lock do |file|
          file.write(document) unless regresses?(file, facts.generation)
        end
      end

      # Another pid's document is a killed daemon's and is replaced whatever
      # its generation says: the home lock proves that process is gone.
      def regresses?(file, generation)
        current = file.read
        !current.nil? && current["pid"] == Process.pid && current["generation"].to_i > generation
      rescue StateError
        false
      end

      def announcement_document(facts)
        {
          "version" => ANNOUNCEMENT_VERSION,
          "state" => facts.state,
          "endpoint" => @endpoint,
          "bearer" => @bearer,
          "pid" => Process.pid,
          "base_url" => @home.base_url,
          "work_root" => @home.work_root,
          "home" => @home.root,
          "started_at" => @clock.call.utc.iso8601,
          "generation" => facts.generation,
        }.merge(transport_facts).merge(connection_facts(facts))
      end

      # Recorded as an assertion, not a verified fact; plaintext carries a
      # standing warning because anyone on the path can read the bearer.
      def transport_facts
        return {} if @transport_assertion.nil?

        facts = { "transport_assertion" => @transport_assertion.to_s }
        if @transport_assertion == :plaintext
          facts["warning"] = "bound #{@bind} in plaintext by operator acknowledgement; " \
            "anyone on the path can read this bearer"
        end
        facts
      end

      def connection_facts(facts)
        document = {}
        document["connection"] = facts.connection_document if facts.connection_document
        if facts.identity
          document["identity"] = Lineage::Status.identity_facts(facts.identity).transform_keys(&:to_s)
        end
        document
      end
  end
end
