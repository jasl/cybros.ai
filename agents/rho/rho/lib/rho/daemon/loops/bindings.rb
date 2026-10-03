module Rho
  class Daemon
    class Loops
      # THE TURN AUTHOR READS THE BINDING, whoever wrote it: a
      # host's runner-kind calls land on the runner its row names — the
      # create's answer, a handoff this daemon made, a `runner_bound` it
      # followed — and BEFORE a turn is rendered the author asks which. This
      # machine's own runner (or none) keeps the local bytes: the local
      # environment block and the local registry, unchanged to the byte.
      # Another runner renders that runner's announced SNAPSHOT as the lead
      # and narrows the turn's `tool_names` to the kernel's ∪ this rho's
      # agent-served ∪ that runner's announced names — never nil, because
      # the profile's declaration is the UNION over every bound or selected
      # runner and nil would run the whole of it. The union is declared
      # only when its bytes move (one digest), because a re-declaration
      # busts every host's cached prefix.
      module Bindings
        # A turn's surface, resolved once from the binding: the runner it is
        # for, whether that runner is elsewhere, the lead the turn opens
        # with, the environment the tools are bound to (nil when they run
        # elsewhere), and the two name sets the narrowing unions with the
        # kernel's — the runner's announced names, and this rho's own that
        # still apply (all of them locally; the agent-served alone remotely).
        Surface = Data.define(:runner, :remote, :lead, :environment, :runner_names, :own_names) do
          def remote? = remote
        end

        # ---- the daemon-lifetime cache of runners elsewhere ----

        def remote_runners = @remote_runners ||= Rho::RemoteRunners.new

        # The discovery document as last read, fetched on a miss through
        # the client given (a verb's own) or the member plane. A runner
        # discovery does not list — reaped, revoked, out of this profile's
        # scope — answers nil and says so once per ask; the kernel's own
        # refusal, if a create or a claim meets one, is the caller's to read.
        def remote_runner(public_id, client: nil)
          return nil if public_id.nil?

          remote_runners.get(public_id) || fetch_remote_runner(public_id, client)
        end

        def learn_runner(document) = remote_runners.put(document)

        # ---- the store's view of the bindings ----

        # What `say` resolves a verb's id by — the host's own id or its
        # backing loop's — with the binding facts the row keeps.
        def host_binding(public_id)
          row = store.find(public_id)
          if row.nil?
            run = backed_by(public_id)
            row = store.find(run.public_id) if run
          end
          row && binding_facts(row)
        rescue Rho::StateError => error
          @log.warn("loops.host_binding_read_failed", host: public_id, detail: error.message)
          nil
        end

        def host_bindings
          store.rows.map { |row| binding_facts(row) }
        rescue Rho::StateError => error
          @log.warn("loops.host_bindings_read_failed", detail: error.message)
          []
        end

        # Scope is not attachment: an unfollowed child remains unfollowed,
        # but its parent's kernel listing identifies the workspace to use.
        def host_workspace(public_id)
          binding = host_binding(public_id)
          return binding.fetch(:workspace) if binding

          parent = @lineage.runs.find { |run| run.host? && run.child?(public_id) }
          parent && store.find(parent.public_id)&.workspace
        rescue Rho::StateError => error
          @log.warn("loops.host_workspace_read_failed", host: public_id, detail: error.message)
          nil
        end

        # ---- the union, declared on change ----

        # The profile's declaration written from the member plane: the
        # handoff verb, the `runner_bound` follow, `rho runners` after its
        # refresh. Answers the declaration's outcome: `:declared`,
        # `:unchanged` when the bytes did not move, a `Refused` naming the
        # kernel's code — or the member plane's own refusal when there is
        # no plane to declare on. The handoff routes ignore it; the grant
        # route reads it.
        def declare_union
          @context.member_plane(require_workspace: false) { |client, *| declare(client) }
        end

        # ---- the session grants ----
        #
        # THE HOME of the person's `rho approve --always` rules: an Array here, under the one declaring gate, born
        # empty at boot — the session is until the daemon's next boot, so
        # `rho restart` is the revocation; NOT in rho's files (no settings key, no state file: a persistent form is a new settings key and a merge site). The DURABLE copy is the
        # kernel's profile row, whole-replaced by every declaration; the
        # next boot's declaration clears it, and a clean stop re-declares
        # the constant list first (`revoke_grants_and_declare`).

        def grants = @grants

        # THE GRANT'S DECLARATION, one section under the gate (S24): the
        # add and the write serialize against another grant and against
        # the boot's spawned declaration (a waiting fiber parks on the
        # reactor; `Loops#initialize`). `:already` for a rule the list holds
        # (no write); else the union is declared with the rule last —
        # `:declared`, or `Refused`, on which the grant just added is
        # REVOKED before any later edge could re-send the refused list
        # (`@declared` is recorded only on success). The log carries the
        # tool, the path it keys on and the matcher's SIZE, never its text (S29).
        def grant(grant, client)
          @declaring.acquire do
            next :already if @grants.any? { |held| held.rule == grant.rule }

            @grants = (@grants + [grant]).freeze
            outcome = declare_locked(client)
            facts = { tool: grant.rule["tool"], path: grant.rule["path"], bytes: grant.rule["match"].to_s.bytesize }
            if outcome in Refused
              @grants = @grants.reject { |held| held.equal?(grant) }.freeze
              @log.warn("grant.refused", **facts, code: outcome.code)
            else
              @log.info("grant.added", **facts)
            end
            outcome
          end
        end

        # THE ONE LIST as it stands now — the constant, this install's
        # roots' denies over the entries the daemon knows (its own
        # announcement and every cached runner's; a runner not yet read
        # adds its `mcp__` denies at the next declaration), the grants —
        # for the standalone shell (`POST /loops`, S21) and the bytes line
        # of `rho rules`. No kernel read.
        def approval_rules
          served = [LoopRequest.announcement(registry: @loaded.registry, extras: @environments.servers.announcement),
                    *union_members.filter_map { |id| remote_runners.get(id)&.served_tools }]
          LoopRequest.approval_rules(roots: Rho.protected_roots(@home),
            entries: served.flat_map { |list| LoopRequest.served_entries(list) }, grants: @grants.map(&:rule))
        end

        # THE STOP EDGE (S23): the grants forgotten and the constant list
        # written once more, so a clean stop leaves nothing standing on the
        # profile; a refused write is logged by code — best effort, the
        # daemon stops all the same, and the next boot's declaration clears
        # what stood. Nothing granted, nothing written. Answers the count.
        def revoke_grants_and_declare(client)
          @declaring.acquire do
            count = @grants.length
            next 0 if count.zero?

            @grants = [].freeze
            outcome = declare_locked(client)
            if outcome in Refused
              @log.warn("grants.revoke_failed", count: count, code: outcome.code)
            else
              @log.info("grants.revoked_at_stop", count: count)
            end
            count
          end
        end

        # THE PROFILE'S TWO MODELS AS LAST DECLARED — `{default_model,
        # fallback_model}` off the kernel's answer to the declaration, each
        # nil when the profile names none; nil before the first
        # declaration lands. What `rho status` prints: the settings file
        # is the surface, and this is the read of what it stands for.
        def declared_models = @declared_models

        # THE COLLISION CHECK a handoff runs before the bind: the
        # candidate's names this rho or an already-unioned runner declares
        # in other bytes. This machine's own runner collides with nothing.
        def conflicts_with(document)
          return [] if @context.own_runner?(document.public_id)

          others = union_members.reject { |id| id == document.public_id }
          base = LoopRequest.union([own_entries, *others.filter_map { |id| cached_entries(id) }]).entries
          LoopRequest.conflicts(base, LoopRequest.tool_entries(document.served_tools))
        end

        private

          # THE ONE FUNCTION a turn's lead and names come from. Own or none:
          # the local bytes, as at HEAD. Elsewhere: the snapshot and the
          # announced names; a runner discovery cannot show still opens the
          # turn — no lead at all (the guideline is the profile's slot), the kernel's and this rho's agent names alone — and
          # the log says why.
          # `model` picks the turn row whose `lead_hints` ride the lead:
          # per request, so a `--model` whose row
          # differs from the boot's still reads its own hints.
          # `binding` is the conversation's root
          # set — the validated body at `open`, the record's read at `say`
          # — the lead names in place of the daemon default; the record
          # itself is never rendered and `anchor` never reaches a prompt.
          # `own_names` carries the turn's ANCHOR's editor servers beside
          # this rho's own: at `open` there is no
          # anchor yet, so none; at `say` the record's.
          def turn_surface(client, runner, model: nil, working_directory: nil, instructions: nil, binding: nil)
            registry = @loaded.registry
            hints = lead_hints(model)
            extras = @environments.servers.announcement_for(binding&.anchor)
            if runner.nil? || @context.own_runner?(runner)
              environment = Rho::Runner::Environment.local(root: binding&.root || @context.tool_env.root,
                directories: binding ? binding.directories : [], working_directory: working_directory)
              # THE RENDER NAMES ITS ANCHOR: the conventions
              # describer says the port sentence while the anchor's port is
              # live; `anchor` never reaches the prompt itself.
              lead = @environments.describing_lead(binding&.anchor) do
                LoopRequest.lead(registry: registry, environment: environment, instructions: instructions, hints: hints)
              end
              return Surface.new(
                runner: runner, remote: false, environment: environment, lead: lead,
                runner_names: [], own_names: names_of(LoopRequest.tool_entries(LoopRequest.announcement(registry: registry, extras: extras)))
              )
            end

            document = remote_runner(runner, client: client)
            Surface.new(
              runner: runner, remote: true, environment: nil,
              lead: LoopRequest.remote_lead(document&.environment, instructions: instructions, hints: hints,
                root: binding&.root, directories: binding ? binding.directories : []),
              runner_names: document ? names_of(LoopRequest.tool_entries(document.served_tools)) : [],
              own_names: names_of(LoopRequest.tool_entries(LoopRequest.announcement(registry: registry.serving(:agent), extras: extras)))
            )
          end

          # THE ONE PLACE A TURN'S TOOL SET IS DECIDED on this side: the tier
          # from the resolver — its compose rung the model's adaptation row
          # — the profile's whole declaration as rho
          # assembles it — the UNION over the bound and selected runners,
          # the same bytes boot and every handoff write — and the subset by
          # name the input carries: the tier's, narrowed to this host's
          # runner whenever the union holds a name from elsewhere, so a host
          # is never offered another runner's tools. No style view: the
          # declaration is the BOOT row's universe and every turn sees the
          # whole of it — the compose narrowing is the one
          # `tool_names` writer. Nothing re-declares the profile per turn —
          # the kernel narrows the declaration by the names.
          # THE EDITORS' SERVERS ARE SUBTRACTED UNCONDITIONALLY: every anchor's `mcp__`
          # names but the turn's own anchor's leave the turn's names whether
          # or not the union holds a runner elsewhere — a turn with no
          # foreign name to subtract keeps the whole declaration (nil) as
          # before. A spawned CHILD's turns are the kernel's (offered the
          # whole declaration; its parent's servers work by anchor); a
          # REMOTE agent's call to a foreign name meets the runner's
          # `Toolsets` and is answered there as data.
          def tier_for(client, model:, compose:, surface:)
            decision = ComposeSwitch.resolve(flag: compose, config: @config, row: compose_row(model))
            members = union_members(extra: surface.runner)
            declared = union_declaration(client, members).fetch(:tool_definitions)
            names = ComposeSwitch.tool_names(declared, decision)
            foreign = @environments.servers.names - surface.own_names
            names = (names || names_of(declared)) - foreign unless foreign.empty?
            unless members.empty?
              allowed = names_of(kernel_tool_definitions(client)) | surface.own_names | surface.runner_names
              names = (names || names_of(declared)) & allowed
            end
            Tier.new(compose: decision, tools: ComposeSwitch.narrow(declared, names), tool_names: names)
          end

          # THE UNION'S MEMBERS: the settings' selection ∪ every followed
          # host's binding ∪ the runner a turn is being opened on, minus
          # this machine's own and none.
          def union_members(extra: nil)
            own = @lineage.identity&.runner_executor_public_id
            rows = begin
              store.rows.map(&:runner)
            rescue Rho::StateError
              []
            end
            ([selected_runner, *rows, extra].compact.uniq - [own]).freeze
          end

          # `roots`: this install's protected roots ride as the
          # self-modification denies on every write; `grants`
          # the session's allow rules, last.
          # `extras`: every anchor's editor servers ride the
          # union beside this machine's own, so the tuple's tool-bytes digest
          # moves when a set moves and the declaration lands once per set.
          def union_declaration(client, members)
            LoopRequest.declaration(
              registry: @loaded.registry, kernel_tools: kernel_tool_definitions(client),
              compaction: compaction_policy, lifecycle_hooks: @config.lifecycle_hooks,
              remote: members.filter_map { |id| remote_runner(id, client: client)&.served_tools },
              roots: Rho.protected_roots(@home), default_model: @config.default_model,
              fallback_model: @config.fallback_model,
              grants: @grants.map(&:rule), extras: @environments.servers.announcement
            )
          end

          # THE DECLARATION, ONCE PER SET OF BYTES per profile: the digest of what was last written for this
          # identity gates the PUT — a handoff to a runner whose names are
          # already in the union moves nothing; a refusal keeps nothing, so
          # the next edge tries again. The rule list rides every write and
          # is a constant of this version — a changed list lands at the
          # next boot (the digest is held in memory, so every boot declares
          # once). THE GUIDELINE lands beside it: rho's
          # `system_prompt` slot on its profile, the first system-role item
          # of every assembled turn — the same constant-of-this-version
          # discipline, under the SAME digest: the pair is recorded only
          # after both landed, so a refused second write leaves both to be
          # retried at the next edge (each is an idempotent replacement).
          # THE BOOT ROW is the universe: its recuts are
          # rendered against the templates the kernel served, and a moved
          # anchor (`AnchorMoved`) refuses the declaration by the entry's
          # name — logged loud, retried at the next edge, never a silent
          # fallback to the plain text. `adaptations.boot_row` says once
          # which row's spellings every turn of this boot runs under. THE
          # SUMMARIZER SLOT lands in the same edge under the same tuple —
          # `[identity, tool-bytes digest, summarizer-text digest | absent,
          # policy digest]`: the
          # slot row's `summarizer_prompt` is written to `summarizer` under
          # a kernel policy, and the slot is DELETED under `off`, a
          # text-less row or `delegate` (write only what is read; the
          # kernel's 404 on an absent slot is landed). THE FOURTH MEMBER is
          # the declaration MINUS its tool bytes — the rule list, the
          # compaction policy, the default and fallback models — so a session grant or a
          # policy change re-declares while identical tool bytes keep the
          # kernel's `tool_definitions` byte-identical (a whole replacement
          # of the same bytes moves no cached prefix).
          # THE OUTCOME IS ANSWERED: `:declared`, `:unchanged`, or
          # `Refused(code:)` — a moved anchor as `anchor_moved`, the
          # kernel's refusal under its own code — under the one gate, so
          # a grant's section and the boot's spawned declaration serialize.
          # THE FIFTH MEMBER: the
          # digest of the named definitions' plan — the derived
          # declarations the edge would PUT, the instance rows it would
          # DELETE, the roster rows the slot would carry — so a changed
          # file, a removed file or a sibling's publish re-declares while
          # an unchanged set writes nothing; recorded from the POST-state
          # (the handles the kernel answered), so the next edge's read
          # finds the same bytes. `force` is the sync's word past the
          # tuple; `publish` names the one definition PUT under `steward`.
          def declare(client) = @declaring.acquire { declare_locked(client) }

          def declare_locked(client, force: false, publish: nil)
            declaration = union_declaration(client, union_members)
            summarizer = summarizer_text(declaration.fetch(:compaction_policy))
            plan = named_plan(client, declaration, publish: publish)
            written = [@lineage.identity&.user_public_id, LoopRequest.digest(declaration.fetch(:tool_definitions)),
                       summarizer ? Digest::SHA256.hexdigest(summarizer) : SUMMARIZER_ABSENT,
                       Digest::SHA256.hexdigest(JSON.generate(declaration.except(:tool_definitions))), plan.digest]
            return :unchanged if !force && written == @declared

            profile = client.profile.declare_configuration(**declaration)
            @declared_models = { default_model: profile.configuration.default_model,
                                 fallback_model: profile.configuration.fallback_model }
            edge = declare_named(client, plan)
            write_guideline(client, edge.roster)
            write_summarizer(client, summarizer)
            @declared = written[0..-2] + [edge.digest]
            @named_edge = edge
            @log.info("profile.declared", tools: declaration.fetch(:tool_definitions).length,
              rules: declaration.fetch(:approval_rules).length,
              compaction: declaration.fetch(:compaction_policy).fetch("mode"), prompt: GUIDELINE_SLOT,
              summarizer: summarizer ? SUMMARIZER_WRITTEN : SUMMARIZER_DELETED, agents: edge.rows.length)
            @log.info("adaptations.boot_row", **@adaptations.facts)
            :declared
          rescue CybrosAgent::ModelAdaptations::AnchorMoved => error
            @log.error("adaptations.anchor_moved", row: @adaptations.boot.id, error: error.message,
              detail: "the profile is not declared under this row; re-cut the entry or pin another row")
            Refused.new(code: "anchor_moved")
          rescue CybrosAgent::Error => error
            @log.warn("profile.declaration_failed", error_class: error.class.name, code: error.code,
              error: CybrosAgent::Redaction.call(error.message))
            Refused.new(code: error.code || error.class.name)
          end

          # The slot the guideline lives in (PromptDocument::SLOTS's word for
          # an agent profile's own identity text).
          GUIDELINE_SLOT = "system_prompt".freeze

          # The guideline, then the roster when there is one: no definition, the guideline alone,
          # byte-identical to before the roster existed.
          def write_guideline(client, roster = nil)
            client.profile.prompt_documents.write(GUIDELINE_SLOT, LoopRequest.guideline_slot(roster))
          rescue CybrosAgent::Error => error
            prompt_failed(GUIDELINE_SLOT, error)
          end

          # The kernel-mode summarizer's slot (PromptDocument's `summarizer`),
          # the profile's own like the guideline; the words `profile.declared`
          # prints beside it, and the tuple's word for no text.
          SUMMARIZER_SLOT = "summarizer".freeze
          SUMMARIZER_WRITTEN = "written".freeze
          SUMMARIZER_DELETED = "deleted".freeze
          SUMMARIZER_ABSENT = "absent".freeze

          def write_summarizer(client, text)
            if text
              client.profile.prompt_documents.write(SUMMARIZER_SLOT, text)
            else
              client.profile.prompt_documents.delete(SUMMARIZER_SLOT)
            end
          rescue CybrosAgent::Api::NotFound
            # Nothing to delete: the slot is absent, which is what was asked.
            nil
          rescue CybrosAgent::Error => error
            prompt_failed(SUMMARIZER_SLOT, error)
          end

          # A refused slot write is written down by name and leaves the tuple
          # unrecorded, so the next edge writes the whole pair again.
          def prompt_failed(slot, error)
            @log.warn("profile.prompt_failed", slot: slot, error_class: error.class.name, code: error.code,
              error: CybrosAgent::Redaction.call(error.message))
            raise error
          end

          # THE HANDOFF FOLLOWED: the row's binding moves to what
          # the feed said (nil after a reap), the runner's document is read
          # again, the union is declared if it moved, and one line reports
          # it — a byte collision the kernel accepted included: never
          # refused here (rho is not the caller), this rho keeps the bytes
          # already declared and that host's turns are offered the union's
          # for the name. The next `say` re-renders the lead (the row's
          # runner now differs from the lead's).
          def follow_runner_bound(run, payload)
            row = store.find(run.public_id)
            return if row.nil?

            executor = payload["executor_public_id"]
            remember(run.host, workspace: row.workspace, live: row.live, runner: executor)
            conflict = nil
            if executor && !@context.own_runner?(executor)
              remote_runners.delete(executor)
              document = remote_runner(executor)
              conflict = document && conflicts_with(document).first
              # THE RECORD FOLLOWS: a handoff made elsewhere is
              # relayed to the new runner here — the document just read
              # handed in — and the records stay: the host still follows.
              relay_record(run.host, executor, document)
            end
            # THE TOOLS LEFT THIS MACHINE: a binding to any runner but this one's — a reap's nil
            # included — ends the conversation for this runner, and its processes here go with it. A
            # move between foreign runners finds nothing to release.
            host_ended(run.host) unless @context.own_runner?(executor)
            declare_union
            @log.info("host.runner_bound", host: run.public_id, executor: executor,
              previous: payload["previous_executor_public_id"], by: payload["by"], conflict: conflict)
          rescue Rho::StateError => error
            @log.warn("loops.runner_bound_not_followed", host: run.public_id, detail: error.message)
          end

          # The conversation's record relayed to a runner elsewhere on the
          # feed's edge — never waited for (the follower must run on); a
          # document discovery could not show relays nothing.
          def relay_record(host, executor, document)
            return unless host.outlives_turn? && document

            binding = @environments.binding_for(host.public_id)
            @environments.assert_remote(host.public_id, executor, binding, document: document, wait: false) if binding
          rescue StandardError => error
            @log.warn("environment.relay_failed", conversation: host.public_id, runner: executor,
              error_class: error.class.name)
          end

          # The `runner:` a verb answers for a row: the binding with the
          # presence the cache holds — no kernel read per `say`; nil for
          # none bound; this machine's own carries the id alone.
          def runner_answer(row)
            return nil if row.runner.nil?

            document = remote_runners.get(row.runner)
            { executor_public_id: row.runner, display_name: document&.display_name,
              presence: document&.presence, last_seen_at: document&.last_seen_at }.compact
          end

          def fetch_remote_runner(public_id, client)
            document = client ? client.executors.show(public_id) : @context.member_plane(require_workspace: false) { |c, *| c.executors.show(public_id) }
            return nil unless document.is_a?(CybrosAgent::Api::DiscoveredExecutor)

            remote_runners.put(document)
          rescue CybrosAgent::Api::NotFound
            @log.info("runner.not_addressable", executor: public_id,
              detail: "discovery lists no such runner for this profile")
            nil
          rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
            @log.warn("runner.discovery_failed", executor: public_id, error_class: error.class.name,
              error: CybrosAgent::Redaction.call(error.message))
            nil
          end

          # The settings' selection as the file says now; a file the person
          # broke costs the selection, never the daemon.
          def selected_runner
            @home.settings_runner
          rescue Rho::ConfigurationError => error
            @log.warn("settings.unreadable", detail: error.message)
            nil
          end

          # This machine's entries with every anchor's editor servers: what
          # the union holds and a handoff's candidate is judged against.
          def own_entries
            LoopRequest.tool_entries(LoopRequest.announcement(registry: @loaded.registry, extras: @environments.servers.announcement))
          end

          def cached_entries(public_id)
            document = remote_runners.get(public_id)
            document && LoopRequest.tool_entries(document.served_tools)
          end

          def names_of(entries) = entries.map { |entry| entry.dig("function", "name") }

          def binding_facts(row)
            { host: row.host, workspace: row.workspace, live: row.live, runner: row.runner }
          end
      end
    end
  end
end
