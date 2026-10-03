require "digest"
require "json"

module Rho
  class Daemon
    class Loops
      # THE NAMED DEFINITIONS' HALF OF THE DECLARE EDGE: at every edge `Bindings#declare_locked`
      # runs — boot, a handoff that moves the union, `rho env`, `rho agents
      # sync` — the daemon combines local and extension definitions, then
      # reads its own and the steward's other published rows off the kernel's one door
      # (`GET profile/agents`), PUTs each scanned definition as a derived
      # declaration under its CURRENT scope (a published name stays
      # published — the publisher keeps it fresh; a new name is
      # `instance`), DELETEs the instance rows whose file went, and hands
      # the ROSTER to the slot write beside the guideline.
      # Registered definitions participate in this same sync and cannot be
      # removed merely because no matching local file exists. The plan's
      # digest joins the declare tuple so an unchanged set writes nothing;
      # the digest is recorded from the POST-state (the handles the kernel
      # assigned), so the next edge's read finds the same bytes.
      #
      # Every kernel refusal of ONE file (a `model: sonnet` the resolver
      # refuses, an `identifier_taken`) costs that file for the boot —
      # logged `agents.declaration_failed`, redacted — never the edge; a
      # refusal of the door itself (a plane gone) is the edge's `Refused`.
      module NamedDefinitions
        # The kernel's scope words (`User.definition_scopes`).
        INSTANCE = "instance".freeze
        STEWARD = "steward".freeze
        # The plan's digest when there is no root to scan: nothing read,
        # nothing written, the slot the guideline alone.
        NO_ROOT = "no-root".freeze

        # What one edge would write, read BEFORE the tuple decides: the
        # scan, the listing as the kernel holds it, this daemon's own rows
        # by name, the steward's other published rows, the derived
        # declarations to PUT (each `{name, scope, description,
        # system_prompt, configuration}`), the instance rows to DELETE, the
        # published rows kept as last declared, and the digest.
        Plan = Data.define(:root, :scan, :listing, :own, :siblings, :derived, :stale, :kept, :digest) do
          def self.none
            new(root: nil, scan: Rho::Agents::Scan.none, listing: [], own: {}, siblings: [], derived: [],
              stale: [], kept: [], digest: NO_ROOT)
          end
        end

        # What one edge wrote: the names PUT, the names DELETEd, the names
        # the kernel refused, the scan's skips, the roster rows the slot
        # carries, the PUT answers by name, and the post-state digest.
        Edge = Data.define(:plan, :declared, :removed, :failed, :rows, :answers, :digest) do
          def self.none(plan) = new(plan: plan, declared: [], removed: [], failed: [], rows: [], answers: {}, digest: plan.digest)
          def skipped = plan.scan.skipped
          def roster = LoopRequest.roster(rows)
        end

        # The last edge's facts, for the routes.
        def named_edge = @named_edge

        # THE SYNC (`rho agents sync`, `rho agents publish NAME`): the whole
        # edge past the tuple, under the declaring gate; answers the edge's
        # facts, or the declaration's `Refused`.
        def sync_named(client, publish: nil)
          @declaring.acquire do
            outcome = declare_locked(client, force: true, publish: publish)
            (outcome in Refused) ? outcome : @named_edge
          end
        end

        # THE LISTING (`rho agents`, read-only): the scan of the moment, the
        # kernel's rows, the publishers' handles off the principals listing.
        def named_listing(client, workspace_public_id)
          plan = named_plan(client)
          handles = principal_handles(client, workspace_public_id, plan.siblings)
          own_paths = plan.scan.definitions.to_h { |definition| [definition.name, definition.path] }
          own = plan.own.values.sort_by(&:name)
          {
            root: plan.root,
            agents: {
              instance: own.select(&:instance?).map { |row| listed(row, path: own_paths[row.name]) },
              nexus: own.select(&:published?).map { |row| listed(row, path: own_paths[row.name]) } +
                plan.siblings.map do |row|
                  listed(row, path: nil, from: handles.fetch(row.derived_from_public_id, row.derived_from_public_id),
                    shadowed_by: own_paths[row.name])
                end,
            },
            skipped: plan.scan.skipped.map { |skipped| { path: skipped.path, reason: skipped.reason } },
          }
        end

        # THE REMOVAL (`rho agents rm NAME`): this daemon's own row of the
        # name, either scope, through the kernel's reversible flip; a
        # sibling's published row is not this instance's to remove.
        def remove_named(client, workspace_public_id, name)
          plan = named_plan(client)
          own = plan.own[name]
          if own
            client.profile.agents.remove(name: name)
            @log.info("agents.removed", name: name, handle: own.handle, scope: own.scope)
            return { removed: presented(own), file: plan.scan.find(name)&.path }
          end

          sibling = plan.siblings.find { |row| row.name == name }
          return Refusal.new(status: 404, code: "not_found", message: "no definition named #{name}; rho agents lists them") if sibling.nil?

          publisher = principal_handles(client, workspace_public_id, [sibling]).fetch(sibling.derived_from_public_id, sibling.derived_from_public_id)
          Refusal.new(status: 404, code: "published_by_sibling",
            message: "#{name} is @#{publisher}'s published definition; the steward removes it on the agents page")
        end

        private

          # THE PLAN: the scan at the environment root, the listing, the
          # derived declarations. With neither root nor registered definitions,
          # nothing is read or planned.
          def named_plan(client, declaration = nil, publish: nil)
            root = @context.environment.root
            return Plan.none if root.nil? && @loaded.agents.empty?

            scan = Rho::Agents.scan(root: root, log: @log, definitions: @loaded.agents)
            listing = client.profile.agents.list
            own_id = @lineage.identity&.user_public_id
            own = listing.select { |row| row.derived_from_public_id == own_id }.to_h { |row| [row.name, row] }
            siblings = listing.reject { |row| row.derived_from_public_id == own_id }.sort_by(&:name)
            derived = derived_declarations(scan, own, declaration || union_declaration(client, union_members), publish)
            kept = own.values.select { |row| row.published? && !scan.names.include?(row.name) }.sort_by(&:name)
            stale = own.values.select { |row| row.instance? && !scan.names.include?(row.name) }.map(&:name).sort
            plan = Plan.new(root: root, scan: scan, listing: listing, own: own, siblings: siblings, derived: derived,
              stale: stale, kept: kept, digest: nil)
            plan.with(digest: named_digest(plan, roster_rows(plan, own)))
          end

          # One derived declaration per scanned definition, under its
          # current scope — `publish` names the one flipped to `steward`.
          def derived_declarations(scan, own, parent, publish)
            agent_names = names_of(LoopRequest.tool_entries(LoopRequest.announcement(registry: @loaded.registry.serving(:agent))))
            scan.definitions.map do |definition|
              scope = definition.name == publish || own[definition.name]&.published? ? STEWARD : INSTANCE
              { name: definition.name, scope: scope, description: definition.description, system_prompt: definition.body,
                configuration: LoopRequest.derived_declaration(parent, definition, agent_names: agent_names, log: @log) }
            end
          end

          # THE WRITES: one PUT per derived declaration (a refused file is
          # logged and costs itself), one DELETE per stale instance row;
          # the roster rows from the answers, the kept rows and the
          # siblings; the post-state digest.
          def declare_named(client, plan)
            return Edge.none(plan) if plan.digest == NO_ROOT

            answers = {}
            failed = []
            plan.derived.each do |entry|
              answer = put_named(client, entry)
              answer ? answers[entry.fetch(:name)] = answer : failed << entry.fetch(:name)
            end
            removed = plan.stale.select { |name| delete_named(client, name) }
            own_after = plan.own.reject { |name, _| removed.include?(name) }.merge(answers)
            rows = roster_rows(plan, own_after)
            @log.info("agents.declared", declared: answers.length, removed: removed.length, failed: failed.length,
              skipped: plan.scan.skipped.length)
            Edge.new(plan: plan, declared: answers.keys, removed: removed, failed: failed, rows: rows, answers: answers,
              digest: named_digest(plan.with(stale: plan.stale - removed), rows))
          end

          def put_named(client, entry)
            client.profile.agents.declare(name: entry.fetch(:name), scope: entry.fetch(:scope),
              description: entry.fetch(:description), display_name: entry.fetch(:name),
              system_prompt: entry.fetch(:system_prompt), configuration: entry.fetch(:configuration))
          rescue CybrosAgent::Api::InvalidRequest, CybrosAgent::Api::Conflict => error
            @log.warn("agents.declaration_failed", name: entry.fetch(:name), code: error.code,
              error: CybrosAgent::Redaction.call(error.message))
            nil
          end

          def delete_named(client, name)
            client.profile.agents.remove(name: name)
            @log.info("agents.removed", name: name, reason: "the file is gone")
            true
          rescue CybrosAgent::Api::NotFound
            true
          end

          # THE ROSTER'S ROWS: this daemon's own rows in scan order (the
          # ones the kernel holds), then its published rows whose file
          # went, then the steward's other published rows not shadowed by
          # an own name — one line per NAME.
          def roster_rows(plan, own)
            names = plan.scan.names
            owned = names.filter_map { |name| own[name] }
            shadowed = (owned + plan.kept).map(&:name)
            (owned + plan.kept + plan.siblings.reject { |row| shadowed.include?(row.name) }).map do |row|
              { handle: row.handle, description: row.description, tool_names: tool_names_of(row) }
            end
          end

          # The digest over what the edge writes and what the slot shows.
          def named_digest(plan, rows)
            Digest::SHA256.hexdigest(JSON.generate([plan.derived, plan.stale, rows]))
          end

          def tool_names_of(row) = Array(row.configuration.tool_definitions).map { |entry| entry.dig("function", "name") }

          # The publishers' handles, resolved once over the principals
          # listing; a publisher the workspace does not list keeps its id.
          def principal_handles(client, workspace_public_id, siblings)
            return {} if siblings.empty?

            wanted = siblings.map(&:derived_from_public_id).uniq
            client.workspace(workspace_public_id).principals
              .select { |principal| wanted.include?(principal.public_id) }
              .to_h { |principal| [principal.public_id, principal.handle] }
          rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
            @log.warn("agents.principals_unread", error_class: error.class.name,
              error: CybrosAgent::Redaction.call(error.message))
            {}
          end

          # `fallback` is the row's declared fallback on refusal, beside its
          # model: what a step it answers re-runs on once a provider declined it.
          def listed(row, path:, from: nil, shadowed_by: nil)
            presented(row).merge(model: row.configuration.default_model, fallback: row.configuration.fallback_model,
              tools: tool_names_of(row).sort, path: path, from: from, shadowed_by: shadowed_by).compact
          end

          # A row as the routes answer it: the listing's shape, the
          # configuration block plain.
          def presented(row) = row.to_h.merge(configuration: row.configuration.to_h)
      end
    end
  end
end
