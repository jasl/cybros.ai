require_relative "../../role_declarations"

module Rho
  class Daemon
    class HostFollowers
      module Presets
        # Advertise the installation's capabilities before any one Preset
        # narrows them. Kernel aliases retain their actual callable names;
        # application and Runner tools stay independently selectable.
        def preset_tool_choices(client)
          base = profile_declaration(client, runner_candidates(client))
          catalog = kernel_catalog(client)
          choices = base.fetch(:kernel_tools).map do |canonical|
            { name: catalog.wire_names.fetch(canonical, canonical), canonical: canonical, kind: "kernel", description: catalog.descriptions[canonical] }.compact
          end
          choices.concat(PresetExecution::Mcp.without_imports(base.fetch(:tool_definitions), base.fetch(:mcp_directory)).map do |entry|
            canonical = entry["canonical"]
            { name: entry.fetch("function").fetch("name"), canonical: canonical, kind: canonical ? "kernel" : "agent",
              description: entry["description"] || entry.dig("function", "description") || catalog.descriptions[canonical] }.compact
          end)
          choices = choices.uniq { |row| row.fetch(:name) }
          unless base.fetch(:runner_executor_public_ids).empty?
            allowed = base.fetch(:runner_tool_names)
            served = Array(@runner_candidate_ids).flat_map { |id| RunDeclaration.served_entries(remote_runners.get(id)&.tools_for(:runner)) }
            runners = served.filter_map do |entry|
              name = entry.fetch("name")
              next if entry["mcp"] || RunDeclaration.undeclared.include?(name) || !entry["description"] || !entry["input_schema"]
              next if allowed && !allowed.include?(name)

              { name: name, kind: "runner", description: entry["description"] }
            end
            choices.concat(runners.uniq { |row| row.fetch(:name) }.sort_by { |row| row.fetch(:name) })
          end

          { tools: choices, mcp_connections: PresetExecution::Mcp.public_directory(base.fetch(:mcp_directory)) }
        end

        def preset_catalog(client)
          AgentPresets.new(store: -> { client.profile.store_entries })
        end

        def preset_declaration(client, answerer: nil, base: nil)
          base ||= profile_declaration(client, Array(@runner_candidate_ids).filter_map { |id| remote_runners.get(id) })
          if answerer && (definition = @loaded.agents.find { |entry| entry.name == answerer.name })
            # An extension owns this declaration. An editable Bot Preset must
            # neither replace its prompt nor widen its selected tools.
            entry = declaration_entry(base, definition, display_name: answerer.display_name, scope: answerer.scope)
            declaration = entry.fetch(:configuration).merge(system_prompt: { "content" => definition.body })
            declaration[:summarizer] = summarizer_text(declaration.fetch(:compaction_policy))&.then { |text| { "content" => text } }
            return declaration
          end

          catalog = preset_catalog(client)
          settings = bot_settings(client, answerer.public_id).read if answerer
          preset_id = if answerer
            settings.preset_public_id || catalog.default_bot_preset_public_id
          else
            catalog.main_preset_public_id
          end
          preset = catalog.fetch(preset_id)
          declaration = if answerer
            bot_preset_declaration(client, preset, base, settings, send_targets: bot_send_targets(client, base: base, answerer: answerer))
          else
            compile_preset_declaration(client, preset, base)
          end
          declaration
        end

        def compile_preset_declaration(client, preset, base, settings: nil, send_targets: [])
          declaration = RoleDeclarations.compile(preset: preset, presets: preset_catalog(client).list,
            base: base, wire_names: kernel_catalog(client).wire_names,
            audience: settings&.audience || "owner", send_targets: send_targets)
          declaration[:summarizer] = summarizer_text(declaration.fetch(:compaction_policy))&.then { |text| { "content" => text } }
          declaration.fetch(:delegation_catalog).each do |entry|
            child = entry.fetch("declaration")
            child["summarizer"] = summarizer_text(child.fetch("compaction_policy"))&.then { |text| { "content" => text } }
          end
          declaration
        end

        def preset_selection(client, body:, answerer: nil, prior: nil, inherited_model: nil)
          declaration = @declaring.acquire do
            base = profile_declaration(client, runner_candidates(client))
            outcome = declare_locked(client, base: base)
            if outcome in Refused
              raise CybrosAgent::Api::InvalidRequest.new("profile declaration failed", code: outcome.code)
            end
            preset_declaration(client, answerer: answerer, base: base)
          end
          PresetExecution.selection(body: body, declaration: declaration, prior: prior, inherited_model: inherited_model)
        rescue AgentPresets::Error => error
          raise CybrosAgent::Api::InvalidRequest.new(error.message, code: "preset_invalid")
        end

        def conversation_execution(client, workspace, public_id, body:, document: nil)
          hosted = workspace.conversation(public_id)
          document ||= hosted.fetch
          addressee = resolve_answerer(client, workspace.public_id, body["to"]) unless body["to"].to_s.empty?
          return addressee if addressee in Refusal

          answerer_id = addressee ? addressee.public_id : document.answering_user_public_id
          if document.agent_configuration_present && answerer_id == document.answering_user_public_id
            return PresetExecution.overrides(body: body)
          end
          answerer = own_named_answerer(answerer_id)
          return {} if answerer_id != @context.own_user_public_id && answerer.nil?

          policy = read_policy(Host::Conversation.new(public_id: public_id), hosted)
          preset_selection(client, body: body, answerer: answerer, prior: policy&.model_selection, inherited_model: @context.conversation_model(public_id, workspace))
        end
      end
    end
  end
end
