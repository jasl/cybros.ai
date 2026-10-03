module Rho
  class Daemon
    class Loops
      # Nexus owns host policy. The follower cache carries a verified projection
      # during replay; admission, attach and restoration read the durable record.
      module Policies
        def restore_policy(host, hosted, live: true, document: nil)
          if host.outlives_turn?
            document ||= hosted.fetch
            policy = read_policy(host, hosted)
            remember(host, workspace: hosted.workspace_public_id, live: live,
              runner: document.runner&.executor_public_id,
              answerer: (document.answering_user_public_id unless document.answering_user_public_id == @context.own_user_public_id))
            store.project(host, policy)
          else
            remember(host, workspace: hosted.workspace_public_id, live: live)
            store.find(host.public_id)
          end
        end

        private

          # An active follower can outlive the bounded restart cache. Restore
          # its projection only on that miss, before a callback uses policy.
          def follow_row(run, hosted)
            store.find(run.public_id) || restore_policy(run.host, hosted, live: run.snapshot.live)
          end

          def policy_for(host, hosted)
            HostPolicy.new(store: -> { hosted.store_entries }, owner_public_id: @context.own_user_public_id,
              host_public_id: host.public_id, initial: -> { legacy_policies.policy(host.public_id) })
          end

          def hydrate_policy(row, hosted)
            store.project(row.host, read_policy(row.host, hosted))
          end

          def read_policy(host, hosted)
            policy = policy_for(host, hosted).read
            legacy_policies.complete(host.public_id)
            policy
          end

          def save_policy(host, hosted, **fields)
            policy = policy_for(host, hosted).change(**fields)
            legacy_policies.complete(host.public_id)
            store.project(host, policy)
          end

          def create_policy(host, hosted, **fields)
            policy = policy_for(host, hosted).replace(**fields)
            legacy_policies.complete(host.public_id)
            store.project(host, policy)
          end

          def legacy_policies
            user = @context.own_user_public_id
            @legacy_policies ||= {}
            @legacy_policies[user] ||= LegacyHostPolicies.new(home: @home, user_public_id: user)
          end
      end
    end
  end
end
