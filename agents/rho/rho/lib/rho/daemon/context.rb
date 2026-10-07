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
                     member_credential:, tool_env:, host_followers:, spawn:, repointed:, environments:,
                     executor_credential: nil, announcements: -> { {} }, settings: nil, refresh_extension: nil, manage_packages: nil)
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
        @host_followers = host_followers
        @spawn = spawn
        @repointed = repointed
        @environments = environments
        @announcements = announcements
        @settings = settings
        @refresh_extension = refresh_extension
        @manage_packages = manage_packages
      end

      attr_reader :bearer

      def home = @host.home

      def log = @host.log

      def clock = @host.clock

      def config = @host.config

      def update_settings(patch, before_save: nil) = @settings.update(patch, before_save: before_save)

      def configure_plugin(id, **options) = @settings.update_plugin(id, **options)

      def plugin_inventory = Extensions::Manager.document(home: home, config: config, loaded: @loaded)

      def refresh_extension(name) = @refresh_extension.call(name)

      def manage_packages(**options) = @manage_packages.call(**options)

      def configure(host:, loaded:, page:)
        @host, @loaded, @page = host, loaded, page
      end

      def clear_environment_override = @environment_store.clear

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
        selected = workspace_public_id || (host_id && @host_followers.call&.host_workspace(host_id))
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

      def runs_for(client, workspace_public_id) = client.workspace(workspace_public_id).runs

      # A conversation id resolves to the run backing its current turn
      # through the store row; a run id passes through
      # untouched. The one resolution every run-grain verb takes.
      def backing_run(public_id) = @host_followers.call.backing_run(public_id)

      def conversation_tool_names(public_id, workspace, **options) = @host_followers.call.conversation_tool_names(public_id, workspace, **options)

      def conversation_code_mode(request, write: false) = @host_followers.call.code_mode(request, self, write: write)

      # The model `say` would send this conversation's next turn on when none
      # is named, or nil when no rung names one.
      def conversation_model(public_id, workspace) = @host_followers.call.conversation_model(public_id, workspace)

      # The newest conversation this daemon follows (not a side), or nil.
      def current_conversation_public_id = @host_followers.call.current_conversation_public_id

      # The member plane, then a RUN id:
      # a conversation id resolves to the run backing its current turn
      # through the store row, so every run-grain verb takes either; a run id passes through untouched.
      def run_command(request)
        member_plane(request, body: true) do |client, workspace_public_id, about, body|
          public_id = body["public_id"].to_s
          next Refusal.malformed("public_id is required") if public_id.empty?

          yield(runs_for(client, workspace_public_id), backing_run(public_id), body,
            workspace_public_id, about)
        end
      end

      # A new host uses its explicit runner, the current saved selection,
      # then this machine's own runner. An explicit null selects none. Existing hosts retain their defaults;
      # the kernel never infers or switches a runner on the caller's behalf.
      def runner_selection(body)
        if body.key?("default_runner_executor_public_id")
          named = body["default_runner_executor_public_id"].to_s
          return named.empty? ? nil : named
        end

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

      # This machine's own Runner row, whose live application guidance rho
      # can add to the environment snapshot Nexus supplies.
      def own_runner?(public_id)
        !public_id.nil? && @lineage.identity&.runner_executor_public_id == public_id
      end

      # ---- the runners elsewhere ----
      #
      # The discovery document as this daemon last read it (fetched on a
      # miss), the document a verb just read handed back to the cache, the
      # profile's source intentions, and the store's bindings — one host's, as
      # `say` resolves an id, or every followed host's. A runner-mode
      # daemon holds no `HostFollowers` and answers nothing.
      def remote_runner(public_id) = @host_followers.call&.remote_runner(public_id)

      def learn_runner(document) = @host_followers.call&.learn_runner(document)

      # Answers the declaration's outcome (`:declared | :unchanged |
      # HostFollowers::Refused`, or a member-plane Refusal); nil with no `HostFollowers`.
      def declare_profile = @host_followers.call&.declare_profile

      def agent_roster = @host_followers.call&.named_edge&.roster

      # ---- the session grants ----
      #
      # The daemon's ONE rule list as it stands now — the constant, the
      # roots' denies, the session grants — which the standalone author
      # names on every run it creates; the grants themselves, for `rho
      # rules`; and the add — approve first, then this — which declares
      # the profile under the one declaring gate and answers its outcome (`:already`,
      # `:declared`, `:unchanged`, `HostFollowers::Refused`). A runner-mode daemon
      # holds no `HostFollowers`: the constant, no grant, and a refusal.
      def approval_rules = @host_followers.call&.approval_rules || Rho::RunDeclaration::APPROVAL_RULES

      def grants = @host_followers.call&.grants || []

      def grant(grant)
        runs = @host_followers.call
        return Refusal.member_plane_unavailable if runs.nil?

        member_plane(require_workspace: false) { |client, *| runs.grant(grant, client) }
      end

      def host_binding(public_id) = @host_followers.call&.host_binding(public_id)

      def host_bindings = @host_followers.call&.host_bindings || []

      def conversation_bindings(public_id)
        @loaded.daemon_hooks.filter_map do |hook|
          next unless hook.event == :conversation_binding

          binding = hook.call(public_id)
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
      def compaction_policy = @host_followers.call.compaction_policy

      # Canonical kernel capabilities and compact aliases for standalone
      # work. Nexus supplies the schemas when the work is created.
      def kernel_tool_configuration(client = nil)
        @host_followers.call.kernel_tool_configuration(client)
      end

      # The model's adaptation row's `lead_hints` —
      # the per-request lines the standalone author appends to its lead as
      # a conversation turn does.
      def lead_hints(model) = @host_followers.call.lead_hints(model)

      # rho's policy over the SDK's adaptations pack: the daemon's own
      # `/adaptations` route answers the resolved row from it.
      def adaptations = @host_followers.call.adaptations

      # The runs this lineage follows; each answers `host?` / `inference_request?`.
      # A RUN id names the host that follows it — its own, or the
      # conversation whose turn it backs.
      def follower(public_id) = @host_followers.call.followed(public_id)

      def followers = @lineage.followers

      def listed_followers = @host_followers.call.listed_followers

      # The one door for a follower: the run is built outside any lock, the
      # lineage installs it with its currency check (`[existing, false]`,
      # `[run, false]` for a moved lineage, `[run, true]`), and it starts here.
      def follow(about, public_id)
        run, adopted = @lineage.install_follower(about, yield(@lineage.realtime_for(about)))
        run.start(method(:spawn)) if adopted
        [run, adopted]
      end

      def adopt_follower(about, host, hosted, body, runs:, document: nil)
        @host_followers.call.restore_policy(host, hosted, live: body["live"] != false, document: document)
        @host_followers.call.adopt_follower(host, hosted, body, runs: runs, about: about)
      end

      def notes(public_id) = @host_followers.call.notes(public_id)

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

      def remember(host, workspace:, live: true, notes: nil, turn: HostStore::KEEP, run_public_id: HostStore::KEEP, model: nil,
                   runner: HostStore::KEEP)
        @host_followers.call.remember(host, workspace: workspace, live: live, notes: notes, turn: turn, run_public_id: run_public_id,
          model: model, runner: runner)
      end

      def forget(host) = @host_followers.call.forget(host)

      # The host a RUN id resolves to, through the one rule: the
      # store first, else the run's own turn block.
      def host_of(public_id, runs) = @host_followers.call.host_of(public_id, runs)

      # This home's own member row, as the kernel keys it — nil before a
      # connection. The principals listing names its steward beside it.
      def own_user_public_id = @lineage.identity&.user_public_id

      # Placement zero's env: the default root's, the announcement's document.
      def tool_env = @tool_env.call

      # THE CONVERSATION'S ENVIRONMENT TABLES: the
      # record's memo and store client, the call_tool's assertions, what this
      # runner slot received, the placements — the conversation door, the
      # default Runner command and the Ops reads reach them here.
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
        declare_profile
        environment
      end

      # ---- the named definitions ----
      #
      # `rho agents`' listing, `sync`/`publish`'s edge past the tuple, and
      # `rm`'s removal — each through the member plane and this daemon's
      # `HostFollowers`; a runner-mode daemon holds none and says so.

      def list_named_definitions = named_verb { |runs, client, workspace| runs.named_listing(client, workspace) }

      # The edge's facts, or the declaration's refusal as a `Refusal` (the
      # one value type a route may hold; `HostFollowers::Refused` stays behind the facade).
      def sync_named_definitions(publish: nil)
        named_verb do |runs, client, _workspace|
          outcome = runs.sync_named(client, publish: publish)
          next outcome unless outcome in HostFollowers::Refused

          Refusal.new(status: 502, code: outcome.code,
            message: "the kernel refused the declaration (#{outcome.code}); the daemon's log has the detail")
        end
      end

      def remove_named_definition(name) = named_verb { |runs, client, workspace| runs.remove_named(client, workspace, name) }

      # Per address: the runner's run and the agent's own, each
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
          runs = @host_followers.call
          return Refusal.member_plane_unavailable if runs.nil?

          member_plane { |client, workspace_public_id, *| yield(runs, client, workspace_public_id) }
        end

        def slot_snapshot(slot, announced)
          @lineage.runner(slot)&.snapshot&.to_h&.merge(
            announced: announced, socket: @lineage.executor_realtime(slot)&.connected? || false
          )
        end
    end
  end
end
