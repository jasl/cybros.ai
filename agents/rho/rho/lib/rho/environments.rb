require "fileutils"
require "monitor"
require "securerandom"
require_relative "environments/inheritance"
require_relative "environments/ports"
require_relative "environments/servers"

module Rho
  # Stores authoring defaults per concrete Executor. Accepted work carries its
  # own binding; the Runner never looks up these records while claiming tasks.
  # This owner also shares local checkpoint stores and editor integrations.
  class Environments
    RECORDS_MAX = 256
    # How far the parent walk climbs before it calls the chain unresolved.
    WALK_DEPTH = 8
    SOURCES = %w[conversation parent default].freeze

    # The memo of one conversation's record: the row's id (nil for a
    # copy memoized before its row was read — a side's fork copy) and
    # the parsed binding; `source` is how it was found.
    Record = Data.define(:public_id, :binding, :source)
    # A read that found nothing, valid for the run that made it.
    Miss = Data.define(:run_public_id)
    # A read's answer: the binding (nil at the default), where it came
    # from, and the row's version and stamp when a row was read.
    Resolved = Data.define(:binding, :source, :public_id, :lock_version, :updated_at) do
      def self.default = new(binding: nil, source: "default", public_id: nil, lock_version: nil, updated_at: nil)
      def root = binding&.root
      def directories = binding ? binding.directories : []
      def anchor = binding&.anchor
    end

    # THE SLOT'S HANDLE: the `Toolsets` the runner gem's `TaskRun`
    # holds (`for`, `names`, `zero`) — a `Toolsets` by class, whose
    # placements come from the `Toolsets` of the moment: placement zero
    # moves under it on `rho env` and the runner stands. It builds nothing
    # of its own (no `super`): every table is the current one's.
    class Slot < Rho::Env::Toolsets
      def initialize(environments, agent: false) # rubocop:disable Lint/MissingSuper
        @environments = environments
        @agent = agent
      end

      def for(task) = current.for(task)

      def names = current.names

      def zero = current.zero

      def ports = current.ports

      def extras = current.extras

      private

        def current = @agent ? @environments.current_agent_toolsets : @environments.current_toolsets
    end

    # Member-plane authoring reads and writes conversation defaults. Both local
    # executor slots share checkpoint stores, ports and editor registrations.
    def initialize(home:, config:, registry:, log:, clock:, default_root:, member_plane:, own_runner:,
                   processes: nil, checkpoints: false, registrar: nil, served: nil,
                   servers_changed: nil, own_runner_public_id: -> { nil })
      @home = home
      @config = config
      @registry = registry
      @log = log
      @clock = clock
      @default_root = default_root
      @member_plane = member_plane
      @own_runner_public_id = own_runner_public_id
      @own_runner = own_runner
      @processes = processes
      @checkpoints = checkpoints
      @servers_changed = servers_changed
      @monitor = Monitor.new
      # THE BUILDS' OWN LOCK, re-entrant and never taken under `@monitor`:
      # placement zero and a root's checkpoint store are built ONCE under
      # concurrent first touch (runtime adoption beside a control verb can
      # reach zero together;
      # two claims on two root sets sharing a root open its store together).
      # Concurrent first use must share the same store handle and limits.
      @builds = Monitor.new
      @records = {}
      @stores = {}
      @flights = {}
      @noticed = {}
      @ports = Ports.new(monitor: @monitor, log: @log)
      @servers = Servers.new(monitor: @monitor, log: @log, registrar: registrar, served: served || registry)
      @toolsets = nil
      @agent_registry = nil
      @agent_toolsets = nil
      @slot = Slot.new(self)
      @agent_slot = Slot.new(self, agent: true)
      # ONE queue per runner: two roots must never interleave
      # writes to one absolute path.
      @mutation_queue = Rho::Env::FileMutationQueue.new
    end

    # ---- placement zero and the runner slot's toolsets ----

    # The runner slot's handle: what the daemon hands `Rho::Env::Executor.new`.
    def toolsets = @slot

    # Publish new consumers under the build lock. Existing calls keep
    # their placement; subsequent calls resolve the new tools and limits
    # through the same slot handles. Process, binding and editor tables
    # survive, as does the queue serializing writes across every root.
    def configure(config:, registry: @registry, agent_registry: @agent_registry,
                  registrar: @servers.registrar, served: @servers.served, checkpoints: @checkpoints)
      @builds.synchronize do
        @config = config
        @registry = registry
        @agent_registry = agent_registry
        @checkpoints = checkpoints
        @servers.configure(registrar: registrar, served: served)
        @monitor.synchronize do
          @toolsets = nil
          @agent_toolsets = nil
          @stores = {}
        end
      end
      self
    end

    # Build the default discovery placement and task-context toolset cache.
    def current_toolsets
      held = @monitor.synchronize { @toolsets }
      return held if held

      @builds.synchronize do
        held = @monitor.synchronize { @toolsets }
        next held if held

        built = build_toolsets
        @monitor.synchronize { @toolsets = built }
        built
      end
    end

    # The default root's placement: the announcement's document, the
    # tools a standalone run runs with, the store the `:startup` prune
    # reads.
    def zero = current_toolsets.zero

    # `rho env`: a new `Toolsets` over a new zero — its env, toolset and
    # store on the new root; the per-root-set placements go with it
    # (their `documents_root` was the old zero's). An in-flight call
    # keeps the env it was built on; the runner stands.
    def rebuild_zero
      @builds.synchronize do
        built = build_toolsets
        @monitor.synchronize do
          @toolsets = built
          @agent_toolsets = nil
        end
        built.zero
      end
    end

    # nil before a root exists (a daemon nobody has connected): the
    # `:startup` prune then prunes nothing.
    def zero_checkpoints
      return nil if @default_root.call.nil?

      zero.env.checkpoints
    end

    # A relayed restore has no conversation placement. Its existing
    # checkpoint record selects the root even after this daemon restarts.
    def checkpoint_stores(id = nil)
      return [] unless @checkpoints

      held = @monitor.synchronize { @stores.values.compact }
      if id
        found = held.find { |store| store.id == id }
        return [found] if found
      end

      roots = Rho::Env::Checkpoints::Store.roots(
        dir: File.join(@home.work_root, Rho::Env::Checkpoints::Store::DIRECTORY), id: id)
      found = roots.filter_map do |root|
        store_for(root)
      rescue SystemCallError
        nil
      end
      id ? found.select { |store| store.id == id } : (held + found).uniq(&:id)
    end

    # Application tools use their own claimed context and anchor for editor
    # servers. They share checkpoint stores with the Runner's local root sets.
    def agent_toolsets(registry)
      @builds.synchronize { @agent_registry ||= registry }
      @agent_slot
    end

    def current_agent_toolsets
      held = @monitor.synchronize { @agent_toolsets }
      return held if held

      @builds.synchronize do
        held = @monitor.synchronize { @agent_toolsets }
        next held if held

        built = Rho::Env::Toolsets.new(
          registry: @agent_registry, zero: zero.env,
          work_dir: @home.work_root, log: @log, checkpoints: (->(root) { store_for(root) } if @checkpoints),
          protected_roots: Rho.protected_roots(@home), extras: @servers
        )
        @monitor.synchronize { @agent_toolsets = built }
        built
      end
    end

    # ---- the record ----

    # Read authoring defaults freshly. An unreadable record refuses capture;
    # a previous memo never supplies an accepted execution's directory.
    def read(conversation, plane: nil, run_public_id: nil, parent: nil, runner: @own_runner_public_id.call)
      plane ||= @member_plane.call(host_public_id: conversation)
      raise CybrosAgent::Api::InvalidRequest.new("Environment records cannot be read without the member plane", code: "executor_environment_unavailable") if plane.nil?

      single_flight([conversation, runner]) do
        resolved = read_record(conversation, plane, runner:) || walk(conversation, plane, run_public_id, parent: parent, runner:)
        next resolved if resolved

        remember(conversation, Miss.new(run_public_id: run_public_id), runner:)
        Resolved.default
      end
    end

    def binding_for(conversation, plane: nil, run_public_id: nil, parent: nil, workspace_public_id: nil, runner: @own_runner_public_id.call)
      plane ||= @member_plane.call(host_public_id: conversation, workspace_public_id: workspace_public_id)
      read(conversation, plane: plane, run_public_id: run_public_id, parent: parent, runner: runner).binding
    end

    # THE WRITE EDGE: read, compare, write under the last-read
    # `lock_version` — a no-op when the whole value is equal; `create`
    # under a per-call key; `key_taken` → another writer won, the update
    # path; one retry on `stale_object`; a second is 409
    # `environment_contended`; never a force. The root set is the
    # caller's validated one; the anchor is the conversation itself.
    # Creation only fills a missing own binding, including on a raced write.
    def bind(conversation, root:, directories:, plane: nil, runner: @own_runner_public_id.call, initialize_only: false)
      plane ||= @member_plane.call(host_public_id: conversation)
      return Daemon::Refusal.member_plane_unavailable if plane.nil?

      binding = Rho::Env::Environment::Binding.new(
        root: runner.nil? || @own_runner.call(runner) ? File.expand_path(root) : root,
        directories: runner.nil? || @own_runner.call(runner) ? Array(directories).map { |path| File.expand_path(path) } : directories, anchor: conversation
      )
      current = read(conversation, plane: plane, runner:)
      return current if keep_binding?(current, binding, initialize_only:)

      written = current.public_id.nil? ? create(conversation, plane, binding, runner:, initialize_only:) : update(conversation, plane, binding, current, runner:, initialize_only:)
      written
    rescue CybrosAgent::Api::Error => error
      Daemon::Refusal.from_api_error(error)
    rescue CybrosAgent::TransportError => error
      Daemon::Refusal.new(status: 502, code: "nexus_error", message: CybrosAgent::Redaction.call(error.message))
    end

    # A null root clears the record: deleted under the read version (a
    # stale version re-reads once); nothing there is done.
    def clear(conversation, plane: nil, runner: @own_runner_public_id.call)
      plane ||= @member_plane.call(host_public_id: conversation)
      return Daemon::Refusal.member_plane_unavailable if plane.nil?

      current = read(conversation, plane: plane, runner:)
      return Resolved.default if current.public_id.nil?

      delete(door(plane, conversation), current.public_id, current.lock_version)
      forget(conversation, runner:)
      Resolved.default
    rescue CybrosAgent::Api::Error => error
      Daemon::Refusal.from_api_error(error)
    end

    # ---- validation ----

    # Local roots are checked here. Remote paths must be absolute and are
    # checked on the selected Runner before its tool executes.
    def refusal_for(path, local: true)
      return "absolute_path_required" unless local || Pathname.new(path).absolute?
      return nil unless local

      spelled = Rho.spelled(path)
      return "protected_root" if Rho.protected_roots(@home).any? { |root| Rho.under?(spelled, root) }
      return "not_a_directory" if local && !File.directory?(spelled)

      nil
    end

    # The door's and the open's check BEFORE anything is created: the
    # root a directory (on this host, when it is this host's to serve)
    # and no member of the set under a protected root.
    def validate(root, directories, local: true)
      root = String.try_convert(root)
      directories = Array.try_convert(directories)
      return Daemon::Refusal.malformed("root must be a path") unless root && !root.empty?
      return Daemon::Refusal.malformed("directories must be a list of paths") unless
        directories && directories.all? { |path| String.try_convert(path) && !path.empty? }

      [root, *directories].each do |path|
        refusal = refusal_for(path, local: local)
        next if refusal.nil?

        return Daemon::Refusal.new(status: 422, code: refusal,
          message: { "protected_root" => "#{path} is under a protected root", "not_a_directory" => "#{path} is not a directory",
            "absolute_path_required" => "#{path} must be an absolute path on the selected Runner" }.fetch(refusal))
      end
      nil
    end

    # ---- the file-system port ----

    # THE DOOR'S REGISTRATION under the record's anchor; the port the
    # runner's lookup answers from then on.
    def register_port(anchor, url:, token:, read:, write:, client:)
      @ports.register(anchor, url: url, token: token, read: read, write: write, client: client)
    end

    def drop_port(anchor, reason:) = @ports.drop(anchor, reason: reason)

    def port_for(anchor) = @ports[anchor]

    def port_live?(anchor) = @ports.live?(anchor)

    def port_description(anchor) = @ports.description(anchor)

    # THE RENDER SCOPE: the lead being
    # rendered names its anchor here for the block's duration — the
    # reactor's fiber, so the key is fiber-local — and the conventions
    # describer asks `lead_port?` from inside `RunDeclaration.lead`. Outside
    # a render (an announcement, a standalone run's seed) nothing has a
    # port.
    LEAD_ANCHOR_KEY = :rho_environments_lead_anchor
    private_constant :LEAD_ANCHOR_KEY

    def describing_lead(anchor)
      previous = Thread.current[LEAD_ANCHOR_KEY]
      Thread.current[LEAD_ANCHOR_KEY] = anchor
      yield
    ensure
      Thread.current[LEAD_ANCHOR_KEY] = previous
    end

    def lead_port? = port_live?(Thread.current[LEAD_ANCHOR_KEY])

    # ---- the editor's servers ----

    # The table itself: the announcement, the declaration and the turn's
    # scope read it (`Daemon::HostFollowers::Bindings`); the runner's agent slot
    # holds it as its `extras`.
    attr_reader :servers

    # THE DOOR'S `mcp:` MEMBER under the record's anchor: the table's
    # answer (a `Servers::Bound`, or the refusal — 422 `mcp_unavailable`,
    # 400 for a list the registrar refuses), the daemon told when the
    # TABLE moved so the agent slot announces the union again — read off
    # the table's digest, not the answer: the held set is closed before
    # the registrar is asked, so a list the registrar
    # refuses has still dropped its predecessor, and the announcement
    # must lose those names too.
    def bind_servers(anchor, entries)
      before = @servers.digest
      bound = @servers.bind(anchor, entries)
      @servers_changed&.call unless @servers.digest == before
      bound
    end

    # The rows for the door's read and the live table.
    def servers_report(anchor) = @servers.report(anchor)

    # THE DAEMON STOPS: every anchor's set closed.
    def shutdown = @servers.shutdown

    # ---- the live table ----

    # One row per explicitly bound Runner on a followed conversation.
    def listing(hosts)
      ids = Array(hosts).map(&:public_id)
      records = @monitor.synchronize { @records.dup }
      records.filter_map do |(conversation, runner), record|
        next unless ids.include?(conversation) && record in Record

        { conversation:, runner:, root: record.binding.root, directories: record.binding.directories,
          anchor: record.binding.anchor, source: record.source,
          fs: port_description(record.binding.anchor), mcp: servers_report(record.binding.anchor) }
      end
    end

    def memo(conversation, runner: @own_runner_public_id.call)
      @monitor.synchronize { @records[[conversation, runner]] }
    end

    # Read only explicit source-qualified records. The retired global binding
    # key is never imported into a Runner selected later.
    def binding_targets(conversation, plane:)
      store = door(plane, conversation)
      page = store.list
      targets = []
      loop do
        page.items.each do |entry|
          next unless entry.namespace == Extensions::Environment::STORE_NAMESPACE
          next unless entry.key.start_with?("#{Extensions::Environment::STORE_KEY}/")

          target = entry.key.delete_prefix("#{Extensions::Environment::STORE_KEY}/")
          targets << (target == "agent" ? nil : target)
        end
        break if page.next_after.nil?

        page = store.list(after: page.next_after)
      end
      targets.uniq
    end

    # THE CONVERSATION ENDED HERE:
    # the call_tool's flight lock, the anchor's port and its editor's servers
    # go (the tools left this machine); the records and the assertions
    # stay (a handoff-away is still followed). Answers whether a served
    # set left the table — the daemon then re-announces the agent slot
    # (`servers_changed`) and re-declares the union.
    def host_ended(conversation)
      @monitor.synchronize { @flights = @flights.reject { |(host, _runner), _flight| host == conversation } }
      @ports.drop(conversation, reason: "host_ended")
      dropped = @servers.host_ended(conversation)
      @servers_changed&.call if dropped
      dropped
    end

    private

      def binding_key(runner) = "#{Extensions::Environment::STORE_KEY}/#{runner || "agent"}"

      def door(plane, conversation)
        plane.client.workspace(plane.workspace_public_id).conversation(conversation).store_entries
      end

      def projection_of(plane, conversation)
        plane.client.workspace(plane.workspace_public_id).conversation(conversation).fetch
      end

      # The conversation's own row, read fresh: by the memo's id, else
      # through the listing. nil when the store holds none.
      def read_record(conversation, plane, runner:)
        memo = memo(conversation, runner:)
        entry = fetch_entry(door(plane, conversation), (memo in Record) ? memo.public_id : nil, runner:)
        return nil if entry.nil?

        binding = Rho::Env::Environment::Binding.parse(entry.value)
        if binding.nil?
          @log&.warn("environment.malformed", conversation: conversation, entry: entry.public_id)
          raise CybrosAgent::Api::InvalidRequest.new("Malformed environment record for #{conversation}", code: "executor_environment_unavailable")
        end

        remember(conversation, Record.new(public_id: entry.public_id, binding: binding, source: "conversation"), runner:)
        Resolved.new(binding: binding, source: "conversation", public_id: entry.public_id,
          lock_version: entry.lock_version, updated_at: entry.updated_at)
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
        notice_once([:unreadable, conversation]) do
          @log&.warn("environment.unreadable", conversation: conversation, error_class: error.class.name,
            code: error.code, error: CybrosAgent::Redaction.call(error.message))
        end
        raise
      end

      def fetch_entry(store, public_id, runner:)
        if public_id
          begin
            return store.fetch(public_id)
          rescue CybrosAgent::Api::NotFound
            nil
          end
        end
        summary = find_summary(store, runner:)
        summary && store.fetch(summary.public_id)
      end

      def find_summary(store, runner:)
        page = store.list
        loop do
          found = page.items.find do |summary|
            summary.namespace == Extensions::Environment::STORE_NAMESPACE && summary.key == binding_key(runner)
          end
          return found if found || page.next_after.nil?

          page = store.list(after: page.next_after)
        end
      end

      def keep_binding?(current, binding, initialize_only:)
        current.source == "conversation" && (current.binding == binding || (initialize_only && current.anchor == binding.anchor))
      end

      def create(conversation, plane, binding, runner:, initialize_only: false)
        entry = door(plane, conversation).create(namespace: Extensions::Environment::STORE_NAMESPACE,
          key: binding_key(runner), value: value_of(binding), idempotency_key: SecureRandom.uuid).store_entry
        written(conversation, entry, binding, runner:)
      rescue CybrosAgent::Api::Conflict => error
        raise unless error.code == "key_taken"

        current = read(conversation, plane: plane, runner:)
        return current if keep_binding?(current, binding, initialize_only:)

        update(conversation, plane, binding, current, runner:, initialize_only:)
      end

      # The update under the read's version; a stale version re-reads —
      # equal now is done, else one retry; a second stale is contended.
      def update(conversation, plane, binding, current, runner:, retried: false, initialize_only: false)
        entry = door(plane, conversation).update(current.public_id, value: value_of(binding), lock_version: current.lock_version)
        written(conversation, entry, binding, runner:)
      rescue CybrosAgent::Api::Conflict => error
        raise unless error.code == "stale_object"

        again = read(conversation, plane: plane, runner:)
        return again if keep_binding?(again, binding, initialize_only:)
        return contended(conversation) if retried || again.public_id.nil?

        update(conversation, plane, binding, again, runner:, retried: true, initialize_only:)
      end

      def contended(conversation)
        Daemon::Refusal.new(status: 409, code: "environment_contended",
          message: "another writer keeps moving #{conversation}'s environment record; retry")
      end

      def delete(store, public_id, lock_version, retried: false)
        store.delete(public_id, lock_version: lock_version)
      rescue CybrosAgent::Api::NotFound
        nil
      rescue CybrosAgent::Api::Conflict => error
        raise if retried || error.code != "stale_object"

        delete(store, public_id, store.fetch(public_id).lock_version, retried: true)
      end

      def written(conversation, entry, binding, runner:)
        remember(conversation, Record.new(public_id: entry.public_id, binding: binding, source: "conversation"), runner:)
        @log&.info("environment.bound", conversation: conversation, root: binding.root,
          directories: binding.directories.length, lock_version: entry.lock_version)
        Resolved.new(binding: binding, source: "conversation", public_id: entry.public_id,
          lock_version: entry.lock_version, updated_at: entry.updated_at)
      end

      def value_of(binding)
        { "root" => binding.root, "directories" => Array(binding.directories), "anchor" => binding.anchor }
      end

      # ---- the memo ----

      def remember(conversation, memo, runner:)
        @monitor.synchronize do
          records = @records.except([conversation, runner]).merge([conversation, runner] => memo)
          records = records.except(records.keys.first) while records.length > RECORDS_MAX
          @records = records
        end
        memo
      end

      def forget(conversation, runner:)
        @monitor.synchronize { @records = @records.except([conversation, runner]) }
      end

      # Two claims of one new child cost one read: the second waits on
      # the first's flight and finds the memo.
      def single_flight(conversation)
        flight = @monitor.synchronize { @flights[conversation] ||= Mutex.new }
        flight.synchronize { yield }
      end

      def notice_once(key)
        fresh = @monitor.synchronize do
          next false if @noticed.key?(key)

          @noticed = @noticed.merge(key => true)
          true
        end
        yield if fresh
      end

      # ---- placement zero ----

      # The default root's env — the announcement's document, the queue
      # every placement shares, the process table, this root's store —
      # under the runner gem's `Toolsets`, which memoizes one env and
      # toolset per captured root set, and refuses a protected root.
      def build_toolsets
        root = @default_root.call
        raise Rho::Error, "the daemon has no environment root yet: connect first, or set one" if root.nil?

        FileUtils.mkdir_p(root)
        env = Rho::Env::ToolEnv.new(
          root: root, artifacts_dir: artifacts_dir_for(root), bash_timeout_seconds: @config.plugin_configuration("rho.coding").fetch("bash_timeout_seconds"),
          processes: @processes, checkpoints: store_for(root), mutation_queue: @mutation_queue,
          checkpoint_resolver: method(:checkpoint_stores).to_proc
        )
        Rho::Env::Toolsets.new(
          registry: @registry, zero: env,
          work_dir: @home.work_root, log: @log, checkpoints: (->(root) { store_for(root) } if @checkpoints),
          protected_roots: Rho.protected_roots(@home), ports: @ports.resolver
        )
      end

      def artifacts_dir_for(root) = Rho::Env::ToolEnv.artifacts_dir_for(root: root, work_dir: @home.work_root)

      # One checkpoint store per real root, under
      # `<work>/checkpoints/`, keyed by the root's digest, opened once
      # per root at bind or first use and never closed on unbind; nil
      # where the daemon opens none, and nil — logged once per root —
      # when the checkpoint database cannot be opened.
      def store_for(root)
        return nil unless @checkpoints

        real = File.realpath(root)
        @builds.synchronize do
          held = @monitor.synchronize { @stores.fetch(real) { :none } }
          next held unless held == :none

          store = open_store(real)
          @monitor.synchronize { @stores = @stores.merge(real => store) }
          store
        end
      end

      def open_store(real)
        Rho::Env::Checkpoints::Store.open(
          dir: File.join(@home.work_root, Rho::Env::Checkpoints::Store::DIRECTORY), root: real,
          protected_roots: Rho.protected_roots(@home), excluded: [artifacts_dir_for(real)], log: @log,
          **@config.plugin_configuration("rho.checkpoints").transform_keys(&:to_sym)
        )
      rescue ArgumentError, Rho::Env::Error, SystemCallError => error
        @log&.warn("checkpoints_unavailable", root: real, error_class: error.class.name,
          detail: CybrosAgent::Redaction.call(error.message))
        nil
      end
  end
end
