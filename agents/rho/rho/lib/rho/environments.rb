require "fileutils"
require "monitor"
require "securerandom"
require_relative "environments/inheritance"
require_relative "environments/ports"
require_relative "environments/relay"
require_relative "environments/servers"

module Rho
  # THE CONVERSATION'S ENVIRONMENT, THE HOST'S SIDE: the record is ONE `store_entries` row
  # at the conversation scope — namespace `rho.environment`, key `binding`, value `{root,
  # directories, anchor}` — the AGENT's own, read through the member plane every turn and
  # written only when a verb names a root set; the runner is TOLD what it needs (in
  # process through `resolve`, elsewhere over the executor relay as `environment_bind`)
  # and never reads the store. ONE instance the daemon owns (never module state: six test
  # files boot daemons in one process); one Monitor over the tables and one re-entrant
  # lock over the builds; every table replaced immutably. OUTSIDE the daemon tree, as
  # `RemoteRunners` is: the lock ranking lets only the lineage construct a lock there, and
  # these tables hold their own monitor. Owned by the daemon; reached through the facade
  # (`Context#environments`).
  #
  # The tables: `records` (a bounded memo of the store, `Record` or a
  # `Miss` per loop, evicted by last touch), `asserted` (what a runner
  # ELSEWHERE was told, keyed by (conversation, runner) → digest + the
  # runner's process life), `received` (what THIS runner slot was told by
  # a host elsewhere), the checkpoint `stores` per real root, `leads`
  # (the tuple the last lead named and whether its anchor had a port, so
  # a moved record or a port that came or went re-renders once), the
  # `ports` (`Environments::Ports`: the editor's file-system port per anchor, the runner's per-call lookup), and the `servers`
  # (`Environments::Servers`: the editor's MCP servers per anchor, served
  # on the agent slot).
  # THE PLACEMENTS are the runner gem's (`Rho::Runner::Toolsets`: one
  # `ToolEnv` + toolset per spelled root set, a miss per loop, the
  # notices): this class owns the runner slot's `Toolsets` of the moment
  # — built on placement zero, the default root's env, and rebuilt on
  # `rho env` — and hands the runner one forwarding handle, so the runner
  # is never rebuilt when the default root moves.
  class Environments
    RECORDS_MAX = 256
    # How far the parent walk climbs before it calls the chain unresolved.
    WALK_DEPTH = 8
    SOURCES = %w[conversation parent default].freeze

    # The memo of one conversation's record: the row's id (nil for a
    # copy memoized before its row was read — a side's fork copy) and
    # the parsed binding; `source` is how it was found.
    Record = Data.define(:public_id, :binding, :source)
    # A read that found nothing, valid for the loop that made it.
    Miss = Data.define(:loop)
    # A read's answer: the binding (nil at the default), where it came
    # from, and the row's version and stamp when a row was read.
    Resolved = Data.define(:binding, :source, :public_id, :lock_version, :updated_at) do
      def self.default = new(binding: nil, source: "default", public_id: nil, lock_version: nil, updated_at: nil)
      def root = binding&.root
      def directories = binding ? binding.directories : []
      def anchor = binding&.anchor
    end

    class Unreadable < Rho::Error; end
    private_constant :Unreadable

    # THE SLOT'S HANDLE: the `Toolsets` the runner gem's `TaskRun`
    # holds (`for`, `names`, `zero`) — a `Toolsets` by class, whose
    # placements come from the `Toolsets` of the moment: placement zero
    # moves under it on `rho env` and the runner stands. It builds nothing
    # of its own (no `super`): every table is the current one's.
    class Slot < Rho::Runner::Toolsets
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

    attr_reader :booted_at

    # `default_root` answers the daemon default's root (the environment
    # store's selection); `member_plane` a `MemberPlane` or nil (a
    # runner-mode daemon holds none); `own_runner` whether an id is this
    # machine's own runner; `learn_runner` puts a refreshed discovery
    # document into the daemon's cache; `spawn` runs a relay fiber on the
    # reactor; `checkpoints` whether the daemon opens shadow stores.
    # `registrar` is the loaded `Extensions::Registrar` for
    # an editor's MCP servers, nil while no extension registered one;
    # `served` the WHOLE registry the servers table judges names against
    # (the runner's alone when not given); `servers_changed` the daemon's
    # edge past a moved set — the agent slot re-announced.
    def initialize(home:, config:, registry:, log:, clock:, booted_at:, default_root:, member_plane:, own_runner:,
                   learn_runner:, spawn:, processes: nil, checkpoints: false, registrar: nil, served: nil,
                   servers_changed: nil)
      @home = home
      @config = config
      @registry = registry
      @log = log
      @clock = clock
      @booted_at = booted_at
      @default_root = default_root
      @member_plane = member_plane
      @own_runner = own_runner
      @learn_runner = learn_runner
      @spawn = spawn
      @processes = processes
      @checkpoints = checkpoints
      @servers_changed = servers_changed
      @monitor = Monitor.new
      # THE BUILDS' OWN LOCK, re-entrant and never taken under `@monitor`:
      # placement zero and a root's shadow store are built ONCE under
      # concurrent first touch (two slots mounted on two threads — the
      # maintenance cycle's adoption beside a verb's — reach zero together;
      # two claims on two root sets sharing a root open its store together).
      # A second `git init` and seed on one shadow store is the race that
      # let the loser record nil for the root.
      @builds = Monitor.new
      @records = {}
      @asserted = {}
      @received = {}
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
      @mutation_queue = Rho::Runner::FileMutationQueue.new
    end

    # ---- placement zero and the runner slot's toolsets ----

    # The runner slot's handle: what the daemon hands `Rho::Runner.new`.
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

    # The `Toolsets` of the moment — built on first use over placement
    # zero, the default root's env; a claim resolves its binding through
    # `resolve` on the worker.
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
    # tools a standalone loop runs with, the store the `:startup` prune
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

      roots = Rho::Runner::Checkpoints::Store.roots(
        dir: File.join(@home.work_root, Rho::Runner::Checkpoints::Store::DIRECTORY), id: id)
      found = roots.filter_map do |root|
        store_for(root)
      rescue SystemCallError
        nil
      end
      id ? found.select { |store| store.id == id } : (held + found).uniq(&:id)
    end

    # THE AGENT SLOT'S TOOLSETS: the given
    # registry's tools — the agent's own — over zero's env, resolving each
    # claim's record on the worker as the runner slot does, for its ANCHOR:
    # the editor's servers the anchor holds (`Servers`, the runner gem's
    # `extras` duck) join the placement, and a call naming another
    # anchor's server is answered as data there. A root set's env is the
    # runner slot's same gesture, so a write-kind server tool captures
    # under the root's store as the runner's writes do; a root absent here
    # lands the agent's own tools on zero and still reaches its anchor's
    # servers. No editor port: the port is the runner's read/edit/write's.
    # Its handle survives both `rho env` and a new registry from settings.
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

        built = Rho::Runner::Toolsets.new(
          registry: @agent_registry, zero: zero.env, resolver: ->(conversation, parent) { resolve(conversation, parent) },
          work_dir: @home.work_root, log: @log, checkpoints: (->(root) { store_for(root) } if @checkpoints),
          protected_roots: Rho.protected_roots(@home), extras: @servers
        )
        @monitor.synchronize { @agent_toolsets = built }
        built
      end
    end

    # THE RESOLVER A CLAIM RUNS ON THE WORKER: the received
    # table — this slot's, or the PARENT's for a spawned child (the
    # kernel's `parent_public_id` on the inbox row) — else, when this
    # daemon has a member plane, the memo, the store or the parent walk;
    # nil lands the claim on placement zero.
    def resolve(conversation, parent = nil)
      context = Rho::Runner::ExecutionContext.current
      binding_for(conversation, loop: context&.agent_loop_public_id, parent: parent,
        workspace_public_id: context&.workspace_public_id)
    end

    # ---- the record ----

    # THE READ EDGE: the memo's id → `fetch`; a miss → `list` → the row →
    # `fetch`; nothing → the parent walk → a `Miss` for the loop. A read
    # that fails keeps the last memo standing (or the default), logs
    # `environment.unreadable` once per conversation, and never refuses.
    def read(conversation, plane: nil, loop: nil, parent: nil)
      plane ||= @member_plane.call(host_public_id: conversation)
      return resolved_from_memo(conversation) if plane.nil?

      single_flight(conversation) do
        resolved = read_record(conversation, plane) || walk(conversation, plane, loop, parent: parent)
        next resolved if resolved

        remember(conversation, Miss.new(loop: loop))
        Resolved.default
      end
    rescue Unreadable
      resolved_from_memo(conversation)
    end

    # THE HOST RESOLVES: what THIS slot received, else the memo (a `Miss` valid for its
    # loop), else what the slot received for the PARENT the inbox row names (a spawned child
    # by its parent's RECEIVED binding, no relay in the path — in every mode that hosts a
    # runner slot), else the store and the walk — the row's parent handed to the walk so no
    # projection read is spent; the host's own memo of the parent is the walk's, AFTER the
    # child's own store is read, so a child's own row is never shadowed by its parent's
    # copy. A slot with NO member plane that was told nothing resolves nothing and says so
    # (`unreceived`) until its binding arrives.
    def binding_for(conversation, plane: nil, loop: nil, parent: nil, workspace_public_id: nil)
      received = received(conversation)
      return received if received

      memo = touch(conversation)
      case memo
      in Record then memo.binding
      in Miss if memo.loop == loop then nil
      else
        plane ||= @member_plane.call(host_public_id: conversation, workspace_public_id: workspace_public_id)
        inherited(conversation, parent, plane) ||
          (plane.nil? ? unreceived(conversation) : read(conversation, plane: plane, loop: loop, parent: parent).binding)
      end
    end

    # THE WRITE EDGE: read, compare, write under the last-read
    # `lock_version` — a no-op when the whole value is equal; `create`
    # under a per-call key; `key_taken` → another writer won, the update
    # path; one retry on `stale_object`; a second is 409
    # `environment_contended`; never a force. The root set is the
    # caller's validated one; the anchor is the conversation itself.
    def bind(conversation, root:, directories:, plane: nil)
      plane ||= @member_plane.call(host_public_id: conversation)
      return Daemon::Refusal.member_plane_unavailable if plane.nil?

      binding = Rho::Runner::Environment::Binding.new(
        root: File.expand_path(root), directories: Array(directories).map { |path| File.expand_path(path) }, anchor: conversation
      )
      current = read(conversation, plane: plane)
      return current if current.source == "conversation" && current.binding == binding

      written = current.public_id.nil? ? create(conversation, plane, binding) : update(conversation, plane, binding, current)
      written
    rescue CybrosAgent::Api::Error => error
      Daemon::Refusal.from_api_error(error)
    rescue CybrosAgent::TransportError => error
      Daemon::Refusal.new(status: 502, code: "nexus_error", message: CybrosAgent::Redaction.call(error.message))
    end

    # A null root clears the record: deleted under the read version (a
    # stale version re-reads once); nothing there is done.
    def clear(conversation, plane: nil)
      plane ||= @member_plane.call(host_public_id: conversation)
      return Daemon::Refusal.member_plane_unavailable if plane.nil?

      current = read(conversation, plane: plane)
      return Resolved.default if current.public_id.nil?

      delete(door(plane, conversation), current.public_id, current.lock_version)
      forget(conversation)
      Resolved.default
    rescue CybrosAgent::Api::Error => error
      Daemon::Refusal.from_api_error(error)
    end

    # ---- validation ----

    # Why a root cannot be placed on this host: under a protected root,
    # or — when the set is this host's to serve (`local`) — not a
    # directory; nil for one that can. A set a runner ELSEWHERE serves is
    # that runner's path (the tools run where the runner is — the box's plain cell of 2026-09-18 opened `/app`, the container's tree, from a host that has no `/app`): the relay's `resolved` says
    # whether it stands there, and this host's placement reads zero.
    def refusal_for(path, local: true)
      spelled = Rho.spelled(path)
      return "protected_root" if Rho.protected_roots(@home).any? { |root| Rho.under?(spelled, root) }
      return "not_a_directory" if local && !File.directory?(spelled)

      nil
    end

    # The door's and the open's check BEFORE anything is created: the
    # root a directory (on this host, when it is this host's to serve)
    # and no member of the set under a protected root.
    def validate(root, directories, local: true)
      return Daemon::Refusal.malformed("root must be a path") unless root.is_a?(String) && !root.empty?
      return Daemon::Refusal.malformed("directories must be a list of paths") unless
        directories.is_a?(Array) && directories.all? { |path| path.is_a?(String) && !path.empty? }

      [root, *directories].each do |path|
        refusal = refusal_for(path, local: local)
        next if refusal.nil?

        return Daemon::Refusal.new(status: 422, code: refusal,
          message: refusal == "protected_root" ? "#{path} is under a protected root" : "#{path} is not a directory")
      end
      nil
    end

    def resolved?(binding) = [binding.root, *binding.directories].all? { |path| refusal_for(path).nil? }

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
    # describer asks `lead_port?` from inside `LoopRequest.lead`. Outside
    # a render (an announcement, a standalone loop's seed) nothing has a
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
    # scope read it (`Daemon::Loops::Bindings`); the runner's agent slot
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

    # One row per followed conversation the memo holds a record for.
    def listing(hosts)
      Array(hosts).filter_map do |host|
        memo = @monitor.synchronize { @records[host.public_id] }
        next unless memo.is_a?(Record)

        relayed = @monitor.synchronize do
          @asserted.find { |(conversation, _runner), _| conversation == host.public_id }
        end
        { conversation: host.public_id, root: memo.binding.root, directories: memo.binding.directories,
          anchor: memo.binding.anchor, source: memo.source,
          relayed: relayed && answer_of(relayed.first.last, relayed.last).to_h,
          fs: port_description(memo.binding.anchor), mcp: servers_report(memo.binding.anchor) }
      end
    end

    def memo(conversation) = @monitor.synchronize { @records[conversation] }

    # THE CONVERSATION ENDED HERE:
    # the relay's flight lock, the anchor's port and its editor's servers
    # go (the tools left this machine); the records and the assertions
    # stay (a handoff-away is still followed). Answers whether a served
    # set left the table — the daemon then re-announces the agent slot
    # (`servers_changed`) and re-declares the union.
    def host_ended(conversation)
      @monitor.synchronize { @flights = @flights.except(conversation) }
      @ports.drop(conversation, reason: "host_ended")
      dropped = @servers.host_ended(conversation)
      @servers_changed&.call if dropped
      dropped
    end

    private

      def member_plane? = !@member_plane.call(require_workspace: false).nil?

      def door(plane, conversation)
        plane.client.workspace(plane.workspace_public_id).conversation(conversation).store_entries
      end

      def projection_of(plane, conversation)
        plane.client.workspace(plane.workspace_public_id).conversation(conversation).fetch
      end

      # The conversation's own row, read fresh: by the memo's id, else
      # through the listing. nil when the store holds none.
      def read_record(conversation, plane)
        memo = memo(conversation)
        entry = fetch_entry(door(plane, conversation), memo.is_a?(Record) ? memo.public_id : nil)
        return nil if entry.nil?

        binding = Rho::Runner::Environment::Binding.parse(entry.value)
        if binding.nil?
          @log&.warn("environment.malformed", conversation: conversation, entry: entry.public_id)
          return nil
        end

        remember(conversation, Record.new(public_id: entry.public_id, binding: binding, source: "conversation"))
        Resolved.new(binding: binding, source: "conversation", public_id: entry.public_id,
          lock_version: entry.lock_version, updated_at: entry.updated_at)
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
        notice_once([:unreadable, conversation]) do
          @log&.warn("environment.unreadable", conversation: conversation, error_class: error.class.name,
            code: (error.code if error.respond_to?(:code)), error: CybrosAgent::Redaction.call(error.message))
        end
        raise Unreadable, error.message
      end

      def fetch_entry(store, public_id)
        if public_id
          begin
            return store.fetch(public_id)
          rescue CybrosAgent::Api::NotFound
            nil
          end
        end
        summary = find_summary(store)
        summary && store.fetch(summary.public_id)
      end

      def find_summary(store)
        page = store.list
        loop do
          found = page.items.find do |summary|
            summary.namespace == Extensions::Environment::STORE_NAMESPACE && summary.key == Extensions::Environment::STORE_KEY
          end
          return found if found || page.next_after.nil?

          page = store.list(after: page.next_after)
        end
      end

      def create(conversation, plane, binding)
        entry = door(plane, conversation).create(namespace: Extensions::Environment::STORE_NAMESPACE,
          key: Extensions::Environment::STORE_KEY, value: value_of(binding), idempotency_key: SecureRandom.uuid)
        written(conversation, entry, binding)
      rescue CybrosAgent::Api::Conflict => error
        raise unless error.code == "key_taken"

        current = read(conversation, plane: plane)
        return current if current.source == "conversation" && current.binding == binding

        update(conversation, plane, binding, current)
      end

      # The update under the read's version; a stale version re-reads —
      # equal now is done, else one retry; a second stale is contended.
      def update(conversation, plane, binding, current, retried: false)
        entry = door(plane, conversation).update(current.public_id, value: value_of(binding), lock_version: current.lock_version)
        written(conversation, entry, binding)
      rescue CybrosAgent::Api::Conflict => error
        raise unless error.code == "stale_object"

        again = read(conversation, plane: plane)
        return again if again.source == "conversation" && again.binding == binding
        return contended(conversation) if retried || again.public_id.nil?

        update(conversation, plane, binding, again, retried: true)
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

      def written(conversation, entry, binding)
        remember(conversation, Record.new(public_id: entry.public_id, binding: binding, source: "conversation"))
        @log&.info("environment.bound", conversation: conversation, root: binding.root,
          directories: binding.directories.length, lock_version: entry.lock_version)
        Resolved.new(binding: binding, source: "conversation", public_id: entry.public_id,
          lock_version: entry.lock_version, updated_at: entry.updated_at)
      end

      def value_of(binding)
        { "root" => binding.root, "directories" => Array(binding.directories), "anchor" => binding.anchor }
      end

      # The parent's binding as this slot RECEIVED it, memoized as the
      # child's copy; with no member plane (runner mode: no store to read,
      # no walk) the slot's memo of the parent too, so a grandchild's
      # chain resolves before the host's relay for the child lands.
      def inherited(conversation, parent, plane)
        return nil if parent.nil?

        binding = received(parent)
        binding ||= memo(parent).then { |memo| memo.binding if memo.is_a?(Record) } if plane.nil?
        return nil if binding.nil?

        remember(conversation, Record.new(public_id: nil, binding: binding, source: "parent"))
        binding
      end

      def resolved_from_memo(conversation)
        memo = memo(conversation)
        return Resolved.default unless memo.is_a?(Record)

        Resolved.new(binding: memo.binding, source: memo.source, public_id: memo.public_id, lock_version: nil, updated_at: nil)
      end

      # ---- the memo ----

      def remember(conversation, memo)
        @monitor.synchronize do
          records = @records.except(conversation).merge(conversation => memo)
          records = records.except(records.keys.first) while records.length > RECORDS_MAX
          @records = records
        end
        memo
      end

      def forget(conversation)
        @monitor.synchronize { @records = @records.except(conversation) }
      end

      # A hit moves to the newest position: eviction is by last touch.
      def touch(conversation)
        @monitor.synchronize do
          memo = @records[conversation]
          @records = @records.except(conversation).merge(conversation => memo) if memo
          memo
        end
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
      # toolset per spelled root set, a miss per loop and the notices,
      # and refuses a protected root as the door does.
      def build_toolsets
        root = @default_root.call
        raise Rho::Error, "the daemon has no environment root yet: connect first, or set one" if root.nil?

        FileUtils.mkdir_p(root)
        env = Rho::Runner::ToolEnv.new(
          root: root, artifacts_dir: artifacts_dir_for(root), bash_timeout_seconds: @config.bash_timeout_seconds,
          processes: @processes, checkpoints: store_for(root), mutation_queue: @mutation_queue,
          checkpoint_resolver: method(:checkpoint_stores).to_proc
        )
        Rho::Runner::Toolsets.new(
          registry: @registry, zero: env, resolver: ->(conversation, parent) { resolve(conversation, parent) },
          work_dir: @home.work_root, log: @log, checkpoints: (->(root) { store_for(root) } if @checkpoints),
          protected_roots: Rho.protected_roots(@home), ports: @ports.resolver
        )
      end

      def artifacts_dir_for(root) = Rho::Runner::ToolEnv.artifacts_dir_for(root: root, work_dir: @home.work_root)

      # THE SHADOW STORE PER REAL ROOT: under
      # `<work>/checkpoints/`, keyed by the root's digest, opened once
      # per root at bind or first use and never closed on unbind; nil
      # where the daemon opens none, and nil — logged once per root —
      # for a git that cannot open the store.
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
        Rho::Runner::Checkpoints::Store.open(
          dir: File.join(@home.work_root, Rho::Runner::Checkpoints::Store::DIRECTORY), root: real,
          protected_roots: Rho.protected_roots(@home), excluded: [artifacts_dir_for(real)], log: @log,
          **@config.checkpoints.except("enabled").transform_keys(&:to_sym)
        )
      rescue ArgumentError, Rho::Runner::Error, SystemCallError => error
        @log&.warn("checkpoints_unavailable", root: real, error_class: error.class.name,
          detail: CybrosAgent::Redaction.call(error.message))
        nil
      end
  end
end
