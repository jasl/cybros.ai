module Rho
  class Daemon
    class HostFollowers
      # Nexus owns host policy. The follower cache carries a verified projection
      # during replay; admission, attach and restoration read the durable record.
      module Policies
        def restore_policy(host, hosted, live: true, document: nil)
          if host.outlives_turn?
            document ||= hosted.fetch
            policy = read_policy(host, hosted)
            remember(host, workspace: hosted.workspace_public_id, live: live,
              runner: document.default_runner&.executor_public_id,
              answerer: (document.answering_user_public_id unless document.answering_user_public_id == @context.own_user_public_id))
            store.project(host, policy)
          else
            remember(host, workspace: hosted.workspace_public_id, live: live)
            store.find(host.public_id)
          end
        end

        def modes(request, ctx, write: false)
          ctx.member_plane(request, body: write) do |client, workspace_public_id, _about, body|
            fields = write ? body : ControlServer.query(request)
            public_id = fields["public_id"].to_s
            next Refusal.malformed("public_id is required") if public_id.empty?
            next Refusal.malformed("code_mode or subagent is required") if write && (fields.keys & %w[code_mode subagent]).empty?
            if write && (refusal = validate_modes(fields))
              next refusal
            end

            host = Rho::Host::Conversation.new(public_id: public_id)
            hosted = host.context(client.workspace(workspace_public_id))
            document = hosted.fetch
            named_answerer = own_named_answerer(document.answering_user_public_id)
            settings = bot_modes(client, named_answerer, captured: document.agent_configuration_present)
            if settings
              next bot_modes_refusal if write
              next [200, { modes: { code_mode: false, subagent: settings.subagent, available: true, code_mode_available: false } }]
            end
            foreign = document.answering_user_public_id != ctx.own_user_public_id && !named_answerer
            next Refusal.malformed("conversation modes belong to rho: the answerer is another agent") if foreign && write
            next [200, { modes: { code_mode: false, subagent: false, available: false, code_mode_available: false } }] if foreign

            policy = if write
              policy_for(host, hosted).change(**fields.slice("code_mode", "subagent").transform_keys(&:to_sym))
            else
              read_policy(host, hosted)
            end
            store.project(host, policy)
            [200, { modes: { code_mode: policy&.code_mode != false, subagent: policy&.subagent != false, available: true,
                            code_mode_available: @config.plugin_enabled?("rho.codemode") } }]
          end
        end

        # Human-authored schedules snapshot the same tools as a new turn.
        # A model-authored schedule already carries its calling round's freeze.
        def conversation_tool_names(public_id, workspace, client:, to: nil, tool_names: nil, include_contexts: false)
          names = tool_names.nil? ? nil : Array.try_convert(tool_names)
          return Refusal.malformed("tool_names must be a list") if !tool_names.nil? && names.nil?

          host = Rho::Host::Conversation.new(public_id: public_id)
          hosted = host.context(workspace)
          document = hosted.fetch
          addressee = to.nil? ? nil : resolve_answerer(client, workspace.public_id, to)
          return addressee if addressee in Refusal

          answerer_id = addressee ? addressee.public_id : document.answering_user_public_id
          named_answerer = own_named_answerer(answerer_id)
          return (include_contexts ? { tool_names: names } : names) if answerer_id != @context.own_user_public_id && !named_answerer

          captured = document.agent_configuration_present && answerer_id == document.answering_user_public_id
          policy = read_policy(host, hosted)
          settings = bot_modes(client, named_answerer, captured: captured)
          enabled = !settings && CodeMode.enabled?(@config, policy&.code_mode != false)
          subagent = settings ? settings.subagent : policy&.subagent != false
          plane = Extensions::MemberPlane.new(client: client, workspace_public_id: workspace.public_id)
          record = @environments.read(public_id, plane: plane, runner: document.default_runner&.executor_public_id)
          surface = turn_surface(client, document.default_runner&.executor_public_id, binding: record&.binding, code_mode: enabled)
          selection = tool_selection(client, surface: surface, code_mode: enabled, subagent: subagent, answerer: named_answerer,
            conversation_public_id: (public_id if captured))
          allowed = names_of(selection.tools)
          selected = names.nil? ? allowed : names & allowed
          return selected unless include_contexts

          return { tool_names: selected } if captured && record&.anchor != public_id

          { tool_names: selected, executor_contexts: captured_contexts(client, tools: selection.tools,
            runner: document.default_runner&.executor_public_id, binding: record&.binding,
            host: public_id, workspace_public_id: workspace.public_id) }
        end

        private

          def bot_modes(client, answerer, captured: false)
            return if answerer.nil? || captured || registered_names.include?(answerer.name)

            bot_settings(client, answerer.public_id).read
          end

          def bot_modes_refusal
            Refusal.new(status: 409, code: "bot_modes_managed",
              message: "Bot Code Mode is off; change Subagent in the Bot settings")
          end

          # An active follower can outlive the bounded restart cache. Restore
          # its projection only on that miss, before a callback uses policy.
          def follow_row(run, hosted)
            store.find(run.public_id) || restore_policy(run.host, hosted, live: run.snapshot.live)
          end

          def policy_for(host, hosted)
            HostPolicy.new(store: -> { hosted.store_entries }, owner_public_id: @context.own_user_public_id,
              host_public_id: host.public_id)
          end

          def hydrate_policy(row, hosted)
            store.project(row.host, read_policy(row.host, hosted))
          end

          def read_policy(host, hosted)
            policy_for(host, hosted).read
          end

          def save_policy(host, hosted, **fields)
            policy = policy_for(host, hosted).change(**fields)
            store.project(host, policy)
          end

          def validate_modes(fields)
            invalid = %w[code_mode subagent].find { |key| fields.key?(key) && !CodeMode.valid?(fields[key]) }
            Refusal.malformed("#{invalid} must be true or false") if invalid
          end

          def create_policy(host, hosted, **fields)
            defaults = { code_mode: CodeMode.enabled?(@config), subagent: @config.subagent_default }
            policy = policy_for(host, hosted).replace(**defaults.merge(fields))
            store.project(host, policy)
          end
      end
    end
  end
end
