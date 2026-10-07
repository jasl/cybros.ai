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

        def code_mode(request, ctx, write: false)
          ctx.member_plane(request, body: write) do |client, workspace_public_id, _about, body|
            fields = write ? body : ControlServer.query(request)
            public_id = fields["public_id"].to_s
            next Refusal.malformed("public_id is required") if public_id.empty?
            next Refusal.malformed("code_mode must be true, false or null") if write &&
              (!fields.key?("code_mode") || !CodeMode.valid?(fields["code_mode"]))

            host = Rho::Host::Conversation.new(public_id: public_id)
            hosted = host.context(client.workspace(workspace_public_id))
            document = hosted.fetch
            foreign = document.answering_user_public_id != ctx.own_user_public_id && !own_named_answerer(document.answering_user_public_id)
            next Refusal.malformed("code_mode belongs to rho: the answerer is another agent") if foreign && write
            next [200, { code_mode: { code_mode: nil, effective: false, available: false } }] if foreign

            policy = if write
              policy_for(host, hosted).change(code_mode: fields["code_mode"])
            else
              read_policy(host, hosted)
            end
            store.project(host, policy)
            [200, { code_mode: { code_mode: policy&.code_mode, effective: CodeMode.enabled?(@config, policy&.code_mode), available: true } }]
          end
        end

        # Human-authored schedules snapshot the same tools as a new turn.
        # A model-authored schedule already carries its calling round's freeze.
        def conversation_tool_names(public_id, workspace, client:, to: nil, tool_names: nil)
          names = tool_names.nil? ? nil : Array.try_convert(tool_names)
          return Refusal.malformed("tool_names must be a list") if !tool_names.nil? && names.nil?

          host = Rho::Host::Conversation.new(public_id: public_id)
          hosted = host.context(workspace)
          document = hosted.fetch
          addressee = to.nil? ? nil : resolve_answerer(client, workspace.public_id, to)
          return addressee if addressee in Refusal

          answerer_id = addressee ? addressee.public_id : document.answering_user_public_id
          named_answerer = own_named_answerer(answerer_id)
          return names if answerer_id != @context.own_user_public_id && !named_answerer

          policy = read_policy(host, hosted)
          enabled = CodeMode.enabled?(@config, policy&.code_mode)
          plane = Extensions::MemberPlane.new(client: client, workspace_public_id: workspace.public_id)
          record = @environments.read(public_id, plane: plane, runner: document.default_runner&.executor_public_id)
          surface = turn_surface(client, document.default_runner&.executor_public_id, binding: record&.binding, code_mode: enabled)
          selection = tool_selection(client, surface: surface, code_mode: enabled, answerer: named_answerer)
          allowed = names_of(selection.tools)
          names.nil? ? allowed : names & allowed
        end

        private

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

          def create_policy(host, hosted, **fields)
            policy = policy_for(host, hosted).replace(**fields)
            store.project(host, policy)
          end
      end
    end
  end
end
