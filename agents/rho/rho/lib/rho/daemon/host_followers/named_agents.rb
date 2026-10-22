require "digest"
require "json"
require_relative "../../bot_policy"

module Rho
  class Daemon
    class HostFollowers
      # Named Users own Bot identity and memory. Their standing configuration
      # is a projection of the selected Preset, refreshed at the declare edge;
      # accepted inputs capture the same compiled value independently.
      module NamedAgents
        # The kernel's scope words (`User.named_agent_scopes`): a bot persists
        # under the steward; an extension's registered row is the instance's.
        STEWARD = "steward".freeze
        INSTANCE = "instance".freeze

        # What one edge would write, read BEFORE the tuple decides: the
        # listing as the kernel holds it, this daemon's own rows by name,
        # the steward's other published rows, each own Bot's settings, the refreshed declarations to
        # PUT (each `{name, scope, description, display_name, system_prompt, summarizer,
        # configuration}`), and the digest.
        Plan = Data.define(:listing, :own, :siblings, :settings, :refreshed, :digest)

        # What one edge wrote: the names PUT, the names the kernel refused,
        # the PUT answers by name, and the
        # post-state digest.
        Edge = Data.define(:plan, :declared, :failed, :answers, :digest)

        # The last edge's facts, for the routes.
        def named_edge = @named_edge

        def declare_bot(client, name:, description:, preset_public_id: nil, display_name: nil,
                        audience: BotSettings::KEEP, welcome_message: BotSettings::KEEP, subagent: BotSettings::KEEP, create_only: false)
          @declaring.acquire do
            if registered_names.include?(name)
              return Refusal.new(status: 409, code: "registered_definition", message: "#{name} is an extension's definition")
            end
            parent = profile_declaration(client, runner_candidates(client))
            plan = named_plan(client, parent)
            row = plan.own[name]
            current = row ? plan.settings.fetch(name) : BotSettings::Snapshot.new(home_workspace_public_id: nil, audience: "owner")
            selected = BotSettings::KEEP.equal?(audience) ? current.audience : audience
            refusal = audience_change_refusal(current.audience, selected)
            return refusal if refusal

            catalog = preset_catalog(client)
            preset_id = preset_public_id || current.preset_public_id || catalog.default_bot_preset_public_id
            preset = catalog.fetch(preset_id)
            settings = current.with(preset_public_id: preset.public_id, audience: selected,
              welcome_message: BotSettings::KEEP.equal?(welcome_message) ? current.welcome_message : welcome_message,
              subagent: BotSettings::KEEP.equal?(subagent) ? current.subagent : subagent)
            targets = external_send_targets(plan.own.values, plan.settings, catalog: catalog, default_model: parent.fetch(:default_model), self_id: row&.public_id)
            declaration = bot_preset_declaration(client, preset, parent, settings, send_targets: targets)
            entry = { name: name, scope: STEWARD, description: description, display_name: display_name || row&.display_name || name,
              system_prompt: declaration.fetch(:system_prompt).fetch("content"),
              summarizer: declaration.dig(:summarizer, "content"),
              configuration: declaration.except(:system_prompt, :summarizer) }
            answer = put_named(client, entry, raise_refusals: true, create_only: create_only || row.nil?)
            bot_settings(client, answer.public_id).replace(preset_public_id: preset.public_id, audience: selected,
              welcome_message: settings.welcome_message, subagent: settings.subagent)
            outcome = declare_locked(client, force: true)
            return outcome if outcome in Refused

            answer
          end
        rescue AgentPresets::Error => error
          Refusal.malformed(error.message)
        end

        # List this daemon's Bots with their current Preset projections,
        # then other applications' published identities.
        def named_listing(client, workspace_public_id)
          plan = named_plan(client)
          handles = principal_handles(client, workspace_public_id, plan.siblings)
          usable = usable_model_refs(client)
          catalog = preset_catalog(client)
          {
            bots: plan.own.values.sort_by(&:name).map do |row|
              listed_own(row, usable: usable, settings: plan.settings[row.name]).tap do |document|
                unless registered_names.include?(row.name)
                  preset = catalog.fetch(plan.settings.fetch(row.name).preset_public_id || catalog.default_bot_preset_public_id)
                  entry = plan.refreshed.find { |item| item.fetch(:name) == row.name }
                  configuration = entry.fetch(:configuration)
                  model = configuration.fetch(:default_model)
                  document.merge!(preset_public_id: preset.public_id, preset_name: preset.name,
                    configuration: configuration, system_prompt: entry.fetch(:system_prompt), model: model,
                    model_standing: model.nil? ? "unset" : (usable.include?(model) ? "available" : "unavailable"),
                    tools: (configuration.fetch(:kernel_tools).map { |name| kernel_catalog(client).wire_names.fetch(name, name) } +
                      configuration.fetch(:tool_definitions).map { |tool| tool.dig("function", "name") } +
                      Array(configuration.fetch(:runner_tool_names)) + configuration.fetch(:mcp_tools).map { |tool| tool.fetch("name") }).uniq.sort)
                end
              end
            end + plan.siblings.map do |row|
              listed(row, usable: usable, from: handles.fetch(row.derived_from_public_id, row.derived_from_public_id))
            end,
          }
        end

        # Publish an external audience only after the kernel has its narrowed
        # policy. Existing accepted work stays frozen; an external identity can
        # never acquire owner capabilities through a later settings change.
        def replace_bot_settings(client, agent_public_id:, home_workspace_public_id: BotSettings::KEEP, audience: BotSettings::KEEP,
                                 preset_public_id: BotSettings::KEEP, welcome_message: BotSettings::KEEP, subagent: BotSettings::KEEP)
          bot_settings_gate(client, agent_public_id) do
            @declaring.acquire do
            row = client.profile.agents.list.find do |candidate|
              candidate.public_id == agent_public_id && candidate.derived_from_public_id == @lineage.identity.user_public_id
            end
            return Refusal.new(status: 404, code: "not_found", message: "no editable bot with public id #{agent_public_id}") if row.nil?
            if registered_names.include?(row.name)
              return Refusal.new(status: 409, code: "registered_definition", message: "#{row.name} is an extension's definition")
            end
            if !BotSettings::KEEP.equal?(home_workspace_public_id) && home_workspace_public_id
              workspace = Workspaces.fetch(client, home_workspace_public_id)
              return workspace if workspace in Refusal
            end
            settings = bot_settings(client, row.public_id)
            current = settings.read
            refusal = audience_change_refusal(current.audience, audience)
            return refusal if refusal
            unless BotSettings::KEEP.equal?(preset_public_id)
              preset_catalog(client).fetch(preset_public_id)
            end
            selected = current.with(
              home_workspace_public_id: BotSettings::KEEP.equal?(home_workspace_public_id) ? current.home_workspace_public_id : home_workspace_public_id,
              audience: BotSettings::KEEP.equal?(audience) ? current.audience : audience,
              preset_public_id: BotSettings::KEEP.equal?(preset_public_id) ? current.preset_public_id : preset_public_id,
              welcome_message: BotSettings::KEEP.equal?(welcome_message) ? current.welcome_message : welcome_message,
              subagent: BotSettings::KEEP.equal?(subagent) ? current.subagent : subagent)
            policy_changed = selected.preset_public_id != current.preset_public_id || selected.audience != current.audience || selected.subagent != current.subagent
            if policy_changed
              parent = profile_declaration(client, runner_candidates(client))
              put_named(client, refreshed_declaration(client, row, parent, selected,
                send_targets: bot_send_targets(client, base: parent, answerer: row)), raise_refusals: true)
            end
            snapshot = settings.replace(**selected.to_h.transform_keys(&:to_sym))
            if policy_changed
              outcome = declare_locked(client, force: true)
              return outcome if outcome in Refused
            end

            snapshot.to_h.merge("agent_public_id" => row.public_id)
            end
          end
        rescue AgentPresets::Error => error
          Refusal.malformed(error.message)
        end

        # Retire this daemon's own Bot through the kernel's reversible flip.
        # Another application's published identity belongs to its publisher.
        def remove_named(client, workspace_public_id, name)
          if registered_names.include?(name)
            return Refusal.new(status: 409, code: "registered_definition", message: "#{name} is an extension's definition; disabling the extension removes it")
          end

          plan = named_plan(client)
          own = plan.own[name]
          if own
            client.profile.agents.remove(name: name)
            @log.info("agents.removed", name: name, handle: own.handle, scope: own.scope)
            outcome = @declaring.acquire { declare_locked(client, force: true) }
            return outcome if outcome in Refused

            return { removed: presented(own) }
          end

          sibling = plan.siblings.find { |row| row.name == name }
          return Refusal.new(status: 404, code: "not_found", message: "no bot named #{name}; rho agents lists them") if sibling.nil?

          publisher = principal_handles(client, workspace_public_id, [sibling]).fetch(sibling.derived_from_public_id, sibling.derived_from_public_id)
          Refusal.new(status: 404, code: "published_by_sibling",
            message: "#{name} is @#{publisher}'s bot; the steward removes it on the agents page")
        end

        private

          # THE PLAN: the listing and every own row refreshed under the
          # parent declaration. Before a workspace is adopted there is no
          # plane to read.
          def named_plan(client, declaration = nil)
            listing = client.profile.agents.list
            own_id = @lineage.identity&.user_public_id
            own = listing.select { |row| row.derived_from_public_id == own_id }.to_h { |row| [row.name, row] }
            siblings = listing.reject { |row| row.derived_from_public_id == own_id }.sort_by(&:name)
            parent = declaration || profile_declaration(client, runner_candidates(client))
            registered = @loaded.agents.map do |definition|
              declaration_entry(parent, definition, display_name: definition.name, scope: own[definition.name]&.scope || INSTANCE)
            end
            bots = own.values.sort_by(&:name).reject { |row| registered_names.include?(row.name) }
            settings = bots.to_h { |row| [row.name, bot_settings(client, row.public_id).read] }
            catalog = preset_catalog(client)
            refreshed = registered + bots.map do |row|
              refreshed_declaration(client, row, parent, settings.fetch(row.name),
                send_targets: external_send_targets(own.values, settings, catalog: catalog, default_model: parent.fetch(:default_model), self_id: row.public_id))
            end
            plan = Plan.new(listing: listing, own: own, siblings: siblings, settings: settings, refreshed: refreshed, digest: nil)
            plan.with(digest: named_digest(refreshed))
          end

          def refreshed_declaration(client, row, parent, settings, send_targets: [])
            catalog = preset_catalog(client)
            preset = catalog.fetch(settings.preset_public_id || catalog.default_bot_preset_public_id)
            declaration = bot_preset_declaration(client, preset, parent, settings, send_targets: send_targets)
            { name: row.name, scope: row.scope, description: row.description, display_name: row.display_name || row.name,
              system_prompt: declaration.fetch(:system_prompt).fetch("content"),
              summarizer: declaration.dig(:summarizer, "content"),
              configuration: declaration.except(:system_prompt, :summarizer) }
          end

          def bot_preset_declaration(client, preset, parent, settings, send_targets: [])
            declaration = compile_preset_declaration(client, preset, parent, settings: settings, send_targets: send_targets)
            runners = declaration.fetch(:runner_executor_public_ids).flat_map do |id|
              RunDeclaration.runner_model_tool_names(remote_runners.get(id)&.tools_for(:runner))
            end.uniq
            BotPolicy.conversation(declaration, subagent: settings.subagent, runner_names: runners)
          end

          def bot_send_targets(client, base:, answerer: nil)
            own = client.profile.agents.list.select { |row| row.derived_from_public_id == @lineage.identity.user_public_id }
            settings = own.reject { |row| registered_names.include?(row.name) }
              .to_h { |row| [row.name, bot_settings(client, row.public_id).read] }
            external_send_targets(own, settings, catalog: preset_catalog(client), default_model: base.fetch(:default_model), self_id: answerer&.public_id)
          end

          def external_send_targets(own, settings, catalog:, default_model:, self_id: nil)
            own.select do |row|
              next true if row.public_id == self_id

              selected = settings[row.name]
              next false unless selected&.audience == "external"

              preset = catalog.fetch(selected.preset_public_id || catalog.default_bot_preset_public_id)
              !!(preset.configuration.fetch("model") || default_model)
            end.sort_by(&:public_id)
          end

          def audience_change_refusal(current, selected)
            if current == "external" && selected == "owner"
              Refusal.new(status: 409, code: "bot_audience_fixed",
                message: "An external Bot stays external; duplicate it to create a private Bot")
            end
          end

          # Extension-registered definitions retain their application-owned
          # declaration and are not editable Bot or Preset documents.
          def declaration_entry(parent, definition, display_name:, scope: STEWARD)
            configuration = RunDeclaration.derived_declaration(parent, definition,
              kernel_tool_names: kernel_catalog(nil).wire_names,
              runner_names: Array(@runner_candidate_ids).flat_map { |id| RunDeclaration.runner_model_tool_names(remote_runners.get(id)&.tools_for(:runner)) }.uniq, log: @log)
            { name: definition.name, scope: scope, description: definition.description, display_name: display_name,
              system_prompt: definition.body,
              summarizer: summarizer_text(configuration.fetch(:compaction_policy)), configuration: configuration }
          end

          # THE WRITES: one PUT per refreshed row (a refused row is logged and
          # costs itself), with the post-state digest.
          def declare_named(client, plan, tolerate_failures: false)
            answers = {}
            failed = []
            plan.refreshed.each do |entry|
              answer = put_named(client, entry, tolerate_failures: tolerate_failures)
              answer ? answers[entry.fetch(:name)] = answer : failed << entry.fetch(:name)
            end
            @log.info("agents.declared", declared: answers.length, failed: failed.length)
            Edge.new(plan: plan, declared: answers.keys, failed: failed, answers: answers,
              digest: failed.empty? ? named_digest(plan.refreshed) : nil)
          end

          def put_named(client, entry, raise_refusals: false, create_only: false, tolerate_failures: false)
            client.profile.agents.declare(name: entry.fetch(:name), scope: entry.fetch(:scope), create_only: create_only,
              description: entry.fetch(:description), display_name: entry.fetch(:display_name),
              system_prompt: entry.fetch(:system_prompt), summarizer: entry.fetch(:summarizer), configuration: entry.fetch(:configuration))
          rescue CybrosAgent::Api::InvalidRequest, CybrosAgent::Api::Conflict => error
            raise if raise_refusals

            named_declaration_failed(entry, error)
          rescue CybrosAgent::Error => error
            raise unless tolerate_failures

            named_declaration_failed(entry, error)
          end

          def named_declaration_failed(entry, error)
            @log.warn("agents.declaration_failed", name: entry.fetch(:name), code: error.code,
              error: CybrosAgent::Redaction.call(error.message))
            nil
          end

          # The digest over the complete declarations written at this edge.
          def named_digest(refreshed)
            Digest::SHA256.hexdigest(JSON.generate(refreshed))
          end

          # The refs the account offers right now, for the model rule.
          def usable_model_refs(client)
            client.models.list.select(&:available?).map(&:ref)
          end

          # Names reserved by loaded extensions.
          def registered_names = @loaded.agents.map(&:name)

          def tool_names_of(row)
            configuration = row.configuration
            kernel_names = configuration.kernel_tools.map { |canonical| kernel_catalog(nil).wire_names.fetch(canonical, canonical) }
            (Array(configuration.tool_definitions).map { |entry| entry.dig("function", "name") } +
              kernel_names + Array(configuration.runner_tool_names) + configuration.mcp_tools.map { |entry| entry.fetch("name") }).uniq
          end

          # The publishers' handles, resolved once over the principals
          # listing; a publisher the workspace does not list keeps its id.
          def principal_handles(client, workspace_public_id, siblings)
            return {} if siblings.empty? || workspace_public_id.nil?

            wanted = siblings.map(&:derived_from_public_id).uniq
            client.workspace(workspace_public_id).principals
              .select { |principal| wanted.include?(principal.public_id) }
              .to_h { |principal| [principal.public_id, principal.handle] }
          rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
            @log.warn("agents.principals_unread", error_class: error.class.name,
              error: CybrosAgent::Redaction.call(error.message))
            {}
          end

          # Current model availability is presentation, not a fallback rule.
          def listed(row, usable:, from: nil, registered: false)
            model = row.configuration.default_model
            standing = model.nil? ? "unset" : (usable.include?(model) ? "available" : "unavailable")
            presented(row).merge(model: model, model_standing: standing,
              tools: tool_names_of(row).sort, from: from, registered: (true if registered)).compact
          end

          def listed_own(row, usable:, settings:)
            registered = registered_names.include?(row.name)
            listed(row, usable: usable, registered: registered).tap do |document|
              document.merge!(settings.to_h.transform_keys(&:to_sym)) unless registered
            end
          end

          def bot_settings(client, public_id)
            BotSettings.new(store: -> { client.profile.store_entries }, agent_public_id: public_id)
          end

          # A row as the routes answer it: the listing's shape, the
          # configuration block plain.
          def presented(row) = row.to_h.merge(configuration: row.configuration.to_h)
      end
    end
  end
end
