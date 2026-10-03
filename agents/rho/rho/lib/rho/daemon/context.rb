module Rho
  class Daemon
    # The facade a route handler sees.
    # A plain class, not a Data: what stands behind it is an ivar with no
    # reader, so no extension is one call away from the daemon's internals.
    class Context
      # `environments` answers the daemon's environment tables, born after this facade; `repointed` is the daemon's
      # edge past a moved default root — placement zero rebuilt, the
      # runner address re-announced — never a rebuilt runner.
      def initialize(host:, bearer:, page:, lineage:, wire:, loaded:, environment_store:, endpoint:,
                     member_credential:, tool_env:, loops:, spawn:, repointed:, environments:,
                     executor_credential: nil, announcements: -> { {} })
        @host = host
        @bearer = bearer
        @page = page
        @lineage = lineage
        @wire = wire
        @loaded = loaded
        @environment_store = environment_store
        @endpoint = endpoint
        @member_credential = member_credential
        @executor_credential = executor_credential
        @tool_env = tool_env
        @loops = loops
        @spawn = spawn
        @repointed = repointed
        @environments = environments
        @announcements = announcements
      end

      attr_reader :bearer

      def home = @host.home

      def log = @host.log

      def clock = @host.clock

      def config = @host.config

      def endpoint = @endpoint.call

      def page? = @page

      def stopping? = @lineage.stopping?

      # The body first, then one decision on a workspace/credential pair read
      # in one section, then the credential fetched outside it, because a
      # rotation may block there. A runner-mode daemon holds no member
      # credential at all and says so before anything else.
      def member_plane(request = nil, body: false, host_public_id: nil, require_workspace: true, workspace_public_id: nil)
        return Refusal.member_plane_unavailable if @member_credential.nil?

        document = body ? ControlServer.json_body(request) : nil
        workspace, about = @lineage.member_plane_snapshot
        credential = about && @member_credential.call(about)
        return Refusal.member_plane_unavailable if credential.nil?

        client = @wire.client(credential_provider: about.method(:member_credential).to_proc)
        fields = document || (request && ControlServer.query(request)) || {}
        host_id = host_public_id || fields["public_id"]
        selected = workspace_public_id || (host_id && @loops.call&.host_workspace(host_id))
        if require_workspace && selected.nil?
          named = fields["workspace_public_id"] || config.workspace_selection(home)
          if named
            row = Workspaces.fetch(client, named)
            return row if row in Refusal

            selected = row.public_id
          else
            return Refusal.workspace_unavailable(workspace) unless workspace.adopted?

            selected = workspace.public_id
          end
        end
        yield(client, selected || workspace.public_id, about, document)
      rescue ConfigurationError => error
        log.warn("settings.unreadable", detail: error.message)
        Refusal.new(status: 422, code: "settings_unreadable", message: error.message)
      end

      # THE AGENT APPLICATION'S OWN PLANE: the executor
      # client on the lineage's transport credential — the inbox this
      # address is listed on, read for its asks and committed on without a
      # token. The same snapshot rule as the member plane; a lineage with
      # no transport credential has no inbox, and says so.
      def executor_plane
        _workspace, about = @lineage.member_plane_snapshot
        credential = about && @executor_credential&.call(about)
        return Refusal.executor_plane_unavailable if credential.nil?

        yield(@wire.executor_client(credential_provider: about.method(:executor_credential).to_proc))
      end

      def loops_for(client, workspace_public_id) = client.workspace(workspace_public_id).agent_loops

      # A conversation id resolves to the loop backing its current turn
      # through the store row; a loop id passes through
      # untouched. The one resolution every loop-grain verb takes.
      def backing_loop(public_id) = @loops.call.backing_loop(public_id)

      # The model `say` would send this conversation's next turn on when none
      # is named, or nil when no rung names one.
      def conversation_model(public_id, workspace) = @loops.call.conversation_model(public_id, workspace)

      # The newest conversation this daemon follows (not a side), or nil.
      def current_conversation_public_id = @loops.call.current_conversation_public_id

      # The member plane, then a LOOP id:
      # a conversation id resolves to the loop backing its current turn
      # through the store row, so every loop-grain verb takes either; a loop id passes through untouched.
      def loop_command(request)
        member_plane(request, body: true) do |client, workspace_public_id, about, body|
          public_id = body["public_id"].to_s
          next Refusal.malformed("public_id is required") if public_id.empty?

          yield(loops_for(client, workspace_public_id), backing_loop(public_id), body,
            workspace_public_id, about)
        end
      end

      # THE RUNNER A NEW HOST STARTS ON, ONE function for `rho do` and the standalone author:
      # the body's own, else the settings' `runner` — read FRESH off the file, because `rho
      # runners use` writes it from the CLI process and the daemon writes settings never
      # (correction (f)) — else this machine's own runner row when it registered one; nil
      # names none, and the host starts unbound (the kernel infers no runner).
      def runner_selection(body)
        body["runner_executor_public_id"].to_s.then { |named| named.empty? ? nil : named } ||
          settings_runner || @lineage.identity&.runner_executor_public_id
      end

      # A settings file the person broke costs the selection (logged), never
      # the verb: the boot already refused the file once; a later break is
      # theirs to see in the log, not a 500 on `rho do`.
      def settings_runner
        home.settings_runner
      rescue ConfigurationError => error
        log.warn("settings.unreadable", detail: error.message)
        nil
      end

      # This machine's own runner row, by id — the one runner whose lead
      # and tools are the local bytes, and which collides with nothing.
      def own_runner?(public_id)
        !public_id.nil? && @lineage.identity&.runner_executor_public_id == public_id
      end

      # ---- the runners elsewhere ----
      #
      # The discovery document as this daemon last read it (fetched on a
      # miss), the document a verb just read handed back to the cache, the
      # collision check a handoff runs before the bind, the union declared
      # when its bytes moved, and the store's bindings — one host's, as
      # `say` resolves an id, or every followed host's. A runner-mode
      # daemon holds no `Loops` and answers nothing.
      def remote_runner(public_id) = @loops.call&.remote_runner(public_id)

      def learn_runner(document) = @loops.call&.learn_runner(document)

      def declaration_conflicts(document) = @loops.call&.conflicts_with(document) || []

      # Answers the declaration's outcome (`:declared | :unchanged |
      # Loops::Refused`, or a member-plane Refusal); nil with no `Loops`.
      def declare_union = @loops.call&.declare_union

      # ---- the session grants ----
      #
      # The daemon's ONE rule list as it stands now — the constant, the
      # roots' denies, the session grants — which the standalone author
      # names on every loop it creates; the grants themselves, for `rho
      # rules`; and the add — approve first, then this — which declares
      # the union under the one declaring gate and answers its outcome (`:already`,
      # `:declared`, `:unchanged`, `Loops::Refused`). A runner-mode daemon
      # holds no `Loops`: the constant, no grant, and a refusal.
      def approval_rules = @loops.call&.approval_rules || Rho::LoopRequest::APPROVAL_RULES

      def grants = @loops.call&.grants || []

      def grant(grant)
        loops = @loops.call
        return Refusal.member_plane_unavailable if loops.nil?

        member_plane(require_workspace: false) { |client, *| loops.grant(grant, client) }
      end

      def host_binding(public_id) = @loops.call&.host_binding(public_id)

      def host_bindings = @loops.call&.host_bindings || []

      def conversation_bindings(public_id)
        @loaded.daemon_hooks.filter_map do |hook|
          next unless hook.event == :conversation_binding

          binding = hook.handler.call(public_id)
          binding&.merge("extension" => hook.extension)
        end
      end

      # This machine's tool registry — what the standalone author declares
      # on a seed and what a hook shaping a turn copies into its rounds.
      def registry = @loaded.registry

      # THE DECLARED COMPACTION POLICY: the settings' policy
      # as the profile declaration sends it — downgraded to the kernel's
      # where this address cannot serve a delegate. One reader: a hook
      # seeding a round copies what was declared, never the settings raw.
      def compaction_policy = @loops.call.compaction_policy

      # The kernel's own tool bytes, fetched never composed; without a
      # client, what the boot declaration fetched; with a `model`, the
      # tier's set for it under the settings.
      def kernel_tool_definitions(client = nil, model: nil)
        @loops.call.kernel_tool_definitions(client, model: model)
      end

      # The model's adaptation row's `lead_hints` —
      # the per-request lines the standalone author appends to its lead as
      # a conversation turn does.
      def lead_hints(model) = @loops.call.lead_hints(model)

      # rho's policy over the SDK's adaptations pack: the daemon's own
      # `/adaptations` route answers the resolved row from it.
      def adaptations = @loops.call.adaptations

      # The runs this lineage follows; each answers `host?` / `one_shot?`.
      # A LOOP id names the host that follows it — its own, or the
      # conversation whose turn it backs.
      def run(public_id) = @loops.call.followed(public_id)

      def runs = @lineage.runs

      # The one door for a follower: the run is built outside any lock, the
      # lineage installs it with its currency check (`[existing, false]`,
      # `[run, false]` for a moved lineage, `[run, true]`), and it starts here.
      def follow(about, public_id)
        run, adopted = @lineage.install_run(about, yield(@lineage.realtime_for(about)))
        run.start(method(:spawn)) if adopted
        [run, adopted]
      end

      def adopt_run(about, host, hosted, body, loops:, document: nil)
        @loops.call.restore_policy(host, hosted, live: body["live"] != false, document: document)
        @loops.call.adopt_run(host, hosted, body, loops: loops, about: about)
      end

      def notes(public_id) = @loops.call.notes(public_id)

      # A LIVE PROCESS THIS DAEMON STARTED under `root`: the guard
      # `rho rewind`/`rho regenerate` read before a restore — restoring
      # under a running server this daemon spawned is the person's to
      # refuse (`rho stop` it first). Answers the process' label, or nil;
      # nil root and a daemon with no table (agent mode, a remote runner)
      # answer nil, so the guard never fires where there is nothing local
      # to protect.
      def live_process_in(root)
        return nil if root.to_s.empty?

        prefix = "#{File.expand_path(root)}/"
        @host.processes&.snapshots&.find do |snapshot|
          next false unless snapshot.live? && snapshot.workdir

          workdir = File.expand_path(snapshot.workdir)
          workdir == File.expand_path(root) || workdir.start_with?(prefix)
        end&.label
      end

      def remember(host, workspace:, live: true, notes: nil, turn: HostStore::KEEP, loop: HostStore::KEEP, model: nil,
                   runner: HostStore::KEEP)
        @loops.call.remember(host, workspace: workspace, live: live, notes: notes, turn: turn, loop: loop,
          model: model, runner: runner)
      end

      def forget(host) = @loops.call.forget(host)

      # The host a LOOP id resolves to, through the one rule: the
      # store first, else the loop's own turn block.
      def host_of(public_id, loops) = @loops.call.host_of(public_id, loops)

      # This home's own member row, as the kernel keys it — nil before a
      # connection. The principals listing names its steward beside it.
      def own_user_public_id = @lineage.identity&.user_public_id

      # Placement zero's env: the default root's, the announcement's document.
      def tool_env = @tool_env.call

      # THE CONVERSATION'S ENVIRONMENT TABLES: the
      # record's memo and store client, the relay's assertions, what this
      # runner slot received, the placements — the conversation door, the
      # handoff verb and the Ops reads reach them here.
      def environments = @environments.call

      # The daemon's own file, then the settings, then this identity's work
      # root — read outside the lock, one identity read. A runner has no
      # user: its work root is keyed by its own address.
      def environment
        @environment_store.select(configured: config.tools_root) do
          identity = @lineage.identity
          user = identity&.user_public_id
          user.nil? ? home.runner_work_root(identity&.executor_public_id.to_s) : home.identity_work_root(user)
        end
      rescue Rho::Error
        # No identity yet, so no work root to fall back to. The settings
        # value if there is one, and otherwise nothing at all — which is
        # the truth for a daemon nobody has connected.
        EnvironmentStore::Selection.new(
          root: config.tools_root,
          source: config.tools_root ? "settings" : "unset"
        )
      end

      # Nil points back to the settings. NEVER REFUSED FOR WORK IN FLIGHT:
      # a move rebuilds placement
      # zero — an in-flight call keeps the env it was built on, the runner
      # is never rebuilt — so the directory is judged at once.
      def repoint_tools(root)
        if root.nil?
          @environment_store.clear
        else
          return Refusal.malformed("root is required") if root.empty?

          expanded = File.expand_path(root)
          unless File.directory?(expanded)
            return Refusal.new(status: 422, code: "not_a_directory", message: "#{expanded} is not a directory")
          end

          @environment_store.write(expanded)
        end
        @repointed.call
        # THE DECLARE EDGE RUNS AGAIN: the
        # named definitions are read at the root, so a moved root re-scans;
        # the tuple makes an unchanged set a no-op, and a refusal is the
        # edge's own log line, never the repoint's.
        declare_union
        environment
      end

      # ---- the named definitions ----
      #
      # `rho agents`' listing, `sync`/`publish`'s edge past the tuple, and
      # `rm`'s removal — each through the member plane and this daemon's
      # `Loops`; a runner-mode daemon holds none and says so.

      def list_named_definitions = named_verb { |loops, client, workspace| loops.named_listing(client, workspace) }

      # The edge's facts, or the declaration's refusal as a `Refusal` (the
      # one value type a route may hold; `Loops::Refused` stays behind the facade).
      def sync_named_definitions(publish: nil)
        named_verb do |loops, client, _workspace|
          outcome = loops.sync_named(client, publish: publish)
          next outcome unless outcome in Loops::Refused

          Refusal.new(status: 502, code: outcome.code,
            message: "the kernel refused the declaration (#{outcome.code}); the daemon's log has the detail")
        end
      end

      def remove_named_definition(name) = named_verb { |loops, client, workspace| loops.remove_named(client, workspace, name) }

      # Per address: the runner's loop and the agent's own, each
      # nil rather than a fabricated idle shape while its slot is not placed
      # — before a workspace is adopted there is no runner, and saying so is
      # the honest answer.
      def runner_snapshot
        announced = @announcements.call
        { runner: slot_snapshot(:runner, announced["runner"]), agent: slot_snapshot(:agent_runner, announced["agent"]) }
      end

      def inventory = @loaded.inventory

      def failures = @loaded.failures

      # The reactor door, resolved at call time.
      def spawn(&) = @spawn.call(&)

      private

        def named_verb
          loops = @loops.call
          return Refusal.member_plane_unavailable if loops.nil?

          member_plane { |client, workspace_public_id, *| yield(loops, client, workspace_public_id) }
        end

        def slot_snapshot(slot, announced)
          @lineage.runner(slot)&.snapshot&.to_h&.merge(
            announced: announced, socket: @lineage.executor_realtime(slot)&.connected? || false
          )
        end
    end
  end
end
