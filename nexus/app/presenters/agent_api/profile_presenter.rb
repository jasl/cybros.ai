module AgentAPI
  # The member plane's bootstrap read: identity, credential and — for an Agent
  # Profile — the standing declaration every turn freezes from. A human
  # declares nothing, so its profile carries no block at all.
  class ProfilePresenter
    class << self
      def full(member:, credential:, measured_at:)
        body = {
          member: {
            public_id: member.public_id,
            handle: member.handle,
            kind: member.kind,
            role: member.role,
            display_name: member.display_name,
          },
          credential: {
            plane: credential.credential_plane,
            expires_at: credential.expires_at,
          },
        }
        body[:configuration] = configuration(member) if member.agent_member?
        body.merge(measured_at: measured_at)
      end

      # A NAMED DEFINITION as the profile's agents door lists it: the
      # principals listing's row plus its scope, its name, the one line
      # the spawner chooses it by, its declarer, and the configuration
      # block whole — no new presenter, the two renderers that exist
      # composed once.
      def named_definition(row)
        PrincipalPresenter.basic(row).merge(
          scope: row.definition_scope,
          name: row.definition_name,
          description: row.description,
          derived_from_public_id: row.derived_from&.public_id,
          configuration: configuration(row)
        )
      end

      # The standing configuration as one block — the profile read's, and the named
      # definitions listing's: ONE renderer of the shape.
      def configuration(member)
        {
          tool_definitions: Array(member.tool_definitions),
          kernel_tools: Array(member.kernel_tools),
          runner_executor_public_ids: Array(member.runner_executor_public_ids),
          runner_tool_names: member.runner_tool_names,
          approval_mode: member.approval_mode,
          approval_rules: member.approval_rules,
          prompt_mechanism: member.prompt_mechanism,
          prompt_template: member.prompt_template,
          compaction_policy: member.compaction_policy,
          lifecycle_hooks: member.lifecycle_hooks,
          default_model: member.default_model,
          fallback_model: member.fallback_model,
        }
      end
    end
  end
end
