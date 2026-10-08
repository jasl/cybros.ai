module Rho
  class Daemon
    class HostFollowers
      # The profile declares candidate environments. Nexus assembles one
      # selected environment when work is created and owns its tool routes.
      module Bindings
        # The default Runner's lead and local environment, together with the
        # Agent/editor names belonging to this conversation's anchor.
        Surface = Data.define(:runner, :remote, :lead, :environment, :own_names) do
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
        # backing run's — with the binding facts the row keeps.
        def host_binding(public_id)
          row = store.find(public_id)
          if row.nil?
            run = backed_by(public_id)
            row = store.find(run.public_id) if run
          end
          row && binding_facts(row)
        rescue Rho::StateError => error
          @log.warn("runs.host_binding_read_failed", host: public_id, detail: error.message)
          nil
        end

        def host_bindings
          store.rows.map { |row| binding_facts(row) }
        rescue Rho::StateError => error
          @log.warn("runs.host_bindings_read_failed", detail: error.message)
          []
        end

        # Scope is not attachment: an unfollowed child remains unfollowed,
        # but its parent's kernel listing identifies the workspace to use.
        def host_workspace(public_id)
          binding = host_binding(public_id)
          return binding.fetch(:workspace) if binding

          parent = @lineage.followers.find { |run| run.host? && run.child?(public_id) }
          parent && store.find(parent.public_id)&.workspace
        rescue Rho::StateError => error
          @log.warn("runs.host_workspace_read_failed", host: public_id, detail: error.message)
          nil
        end

        # ---- the profile intent, declared on change ----

        # The profile's declaration written from the member plane: the
        # default-selection verb, the `default_runner_changed` follow, `rho runners` after its
        # refresh. Answers the declaration's outcome: `:declared`,
        # `:unchanged` when the bytes did not move, a `Refused` naming the
        # kernel's code — or the member plane's own refusal when there is
        # no plane to declare on. The default-selection routes ignore it; the grant
        # route reads it.
        def declare_profile
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
        # reactor; `HostFollowers#initialize`). `:already` for a rule the list holds
        # (no write); else the profile is declared with the rule last —
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
        # for the standalone shell (`POST /runs`, S21) and the bytes line
        # of `rho rules`. No kernel read.
        def guard_enabled? = @loaded.extensions.any? { |extension| extension.name == "rho.guard" }

        def lifecycle_hooks
          if @loaded.extensions.any? { |extension| extension.name == "rho.lifecycle_hooks" }
            @config.plugin_configuration("rho.lifecycle_hooks")
          else
            {}
          end
        end

        def approval_rules
          served = [RunDeclaration.announcement(registry: @loaded.registry, extras: @environments.servers.announcement),
                    *Array(@runner_candidate_ids).filter_map { |id| remote_runners.get(id)&.served_tools }]
          RunDeclaration.approval_rules(guard: guard_enabled?, roots: Rho.protected_roots(@home),
            entries: served.flat_map { |list| RunDeclaration.served_entries(list) }, grants: @grants.map(&:rule))
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

        private

          # Resolve the lead from the selected Runner's local environment or
          # discovered snapshot. An explicit null has no Runner environment.
          # The anchor's editor servers stay scoped to their conversation.
          def turn_surface(client, runner, model: nil, working_directory: nil, instructions: nil, binding: nil, code_mode: true)
            registry = @loaded.registry
            hints = lead_hints(model)
            own_names = ((registry.serving(:agent).names + @environments.servers.names_for(binding&.anchor)).uniq -
              RunDeclaration.undeclared - [Rho::Runner::Tools::Skill::NAME]).sort
            if runner.nil?
              return Surface.new(runner: nil, remote: false, environment: nil, own_names: own_names,
                lead: RunDeclaration.execution_lead(
                  RunDeclaration.lead(registry: registry.serving(:agent), instructions: instructions, hints: hints, code_mode: code_mode),
                  roster: @named_edge&.roster))
            end
            if @context.own_runner?(runner)
              environment = Rho::Runner::Environment.local(root: binding&.root || @context.tool_env.root,
                directories: binding ? binding.directories : [], working_directory: working_directory)
              # THE RENDER NAMES ITS ANCHOR: the conventions
              # describer says the port sentence while the anchor's port is
              # live; `anchor` never reaches the prompt itself.
              lead = @environments.describing_lead(binding&.anchor) do
                RunDeclaration.lead(registry: registry, environment: environment, instructions: instructions, hints: hints, code_mode: code_mode,
                  kernel_environment: true, environment_snapshot: remote_runners.get(runner)&.environment,
                  root: binding&.root, directories: binding ? binding.directories : [])
              end
              return Surface.new(
                runner: runner, remote: false, environment: environment,
                lead: RunDeclaration.execution_lead(lead, roster: @named_edge&.roster),
                own_names: own_names
              )
            end

            document = remote_runner(runner, client: client)
            Surface.new(
              runner: runner, remote: true, environment: nil,
              lead: RunDeclaration.execution_lead(
                RunDeclaration.remote_lead(document&.environment, instructions: instructions, hints: hints,
                  root: binding&.root, directories: binding ? binding.directories : [], kernel_environment: true),
                roster: @named_edge&.roster),
              own_names: own_names
            )
          end

          # Use Nexus's actual assembled names, then apply rho's code-mode and
          # editor policy. Input tool_names remains an exact callable subset.
          def tool_selection(client, surface:, code_mode: true, answerer: nil)
            outcome = declare(client)
            raise CybrosAgent::Api::InvalidRequest.new("profile declaration failed", code: outcome.code) if outcome in Refused

            answerer = own_named_answerer(answerer.public_id) if answerer
            configuration = answerer&.configuration&.to_h&.slice(:tool_definitions, :kernel_tools, :runner_executor_public_ids, :runner_tool_names)&.transform_keys(&:to_s)
            declared = client.tools.assemble(configuration: configuration,
              default_runner_executor_public_id: surface.runner).tool_definitions
            names = names_of(declared) if answerer
            foreign = @environments.servers.names - surface.own_names
            names = names_of(declared) - foreign unless foreign.empty?
            code_names = names_of(declared.select { |entry| CodeMode.code?(entry) })
            names = CodeMode.names(names || names_of(declared), false, code_names: code_names) unless code_mode
            tools = names.nil? ? declared : declared.select { |entry| names.include?(entry.dig("function", "name")) }
            ToolSelection.new(tools: tools, tool_names: names, code_names: code_names)
          end

          def own_named_answerer(public_id)
            return nil if public_id.nil? || @named_edge.nil?

            @named_edge.plan.own.reject { |name, _| @named_edge.removed.include?(name) }
              .merge(@named_edge.answers).values.find { |row| row.public_id == public_id }
          end

          # Candidate authority comes from the Agent's complete discovery read,
          # including offline Runners. Remembered hosts and cache misses never
          # expand that list.
          def runner_candidates(client)
            documents = client.executors.list(kind: "runner")
            documents.each { |document| learn_runner(document) }
            @runner_candidate_ids = documents.map(&:public_id).freeze
            documents
          end

          # `roots`: this install's protected roots ride as the
          # self-modification denies on every write; `grants`
          # the session's allow rules, last.
          # `extras`: every anchor's editor servers ride the
          # Agent declaration, so the tuple's tool-bytes digest
          # moves when a set moves and the declaration lands once per set.
          def profile_declaration(client, candidates)
            RunDeclaration.declaration(
              registry: @loaded.registry, **kernel_tool_configuration(client),
              compaction: compaction_policy, lifecycle_hooks: lifecycle_hooks, guard: guard_enabled?,
              remote: candidates, runner_executor_public_ids: candidates.map(&:public_id),
              roots: Rho.protected_roots(@home), default_model: @config.default_model,
              fallback_model: @config.fallback_model,
              grants: @grants.map(&:rule), extras: @environments.servers.announcement
            )
          end

          # Declare once per accepted set of tools, policy, summarizer and named
          # definitions. Named definitions keep their own commands; their returned
          # handles form the next turn's roster. One atomic Profile PUT replaces
          # the configuration, stable guideline and summarizer. A refused PUT records no
          # digest, so the next edge retries the complete declaration.
          # The in-memory digest resets at boot and never serves as kernel state.
          def declare(client) = @declaring.acquire { declare_locked(client) }

          def declare_locked(client, force: false, publish: nil)
            declaration = profile_declaration(client, runner_candidates(client))
            system_prompt = @config.system_prompt
            summarizer = summarizer_text(declaration.fetch(:compaction_policy))
            plan = named_plan(client, declaration, publish: publish)
            written = [@lineage.identity&.user_public_id, RunDeclaration.digest(declaration.fetch(:tool_definitions)),
                       summarizer ? Digest::SHA256.hexdigest(summarizer) : SUMMARIZER_ABSENT,
                       Digest::SHA256.hexdigest(system_prompt),
                       Digest::SHA256.hexdigest(JSON.generate(declaration.except(:tool_definitions))), plan.digest]
            return :unchanged if !force && written == @declared

            edge = declare_named(client, plan)
            profile = client.profile.declare_configuration(**declaration, prompt_documents: {
              "system_prompt" => { "content" => system_prompt },
              "summarizer" => summarizer && { "content" => summarizer },
            })
            @declared_models = { default_model: profile.configuration.default_model,
                                 fallback_model: profile.configuration.fallback_model }
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

          # Log and digest words for the optional kernel summarizer prompt.
          SUMMARIZER_WRITTEN = "written".freeze
          SUMMARIZER_DELETED = "deleted".freeze
          SUMMARIZER_ABSENT = "absent".freeze

          # A feed update refreshes the convenience default and its discovery
          # document. It changes future lead rendering without transferring
          # roots, processes, accepted tool targets, or historical effects.
          def follow_default_runner_changed(run, payload)
            row = store.find(run.public_id)
            return if row.nil?

            executor = payload["executor_public_id"]
            remember(run.host, workspace: row.workspace, live: row.live, runner: executor)
            if executor && !@context.own_runner?(executor)
              remote_runners.delete(executor)
              remote_runner(executor)
            end
            declare_profile
            @log.info("host.default_runner_changed", host: run.public_id, executor: executor,
              previous: payload["previous_executor_public_id"], by: payload["by"])
          rescue Rho::StateError => error
            @log.warn("runs.default_runner_changed_not_followed", host: run.public_id, detail: error.message)
          end

          # The `default_runner:` a verb answers for a row: the binding with the
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
            return nil if document in Refusal

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

          def names_of(entries) = entries.map { |entry| entry.dig("function", "name") }

          def binding_facts(row)
            { host: row.host, workspace: row.workspace, live: row.live, runner: row.runner }
          end
      end
    end
  end
end
