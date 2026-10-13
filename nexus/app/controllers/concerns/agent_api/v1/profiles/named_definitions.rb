# THE CALLER'S OWN NAMED DEFINITIONS, found the one way: by the composed
# identifier `<caller's identifier>/<name>` among the rows the caller
# minted. A sibling reads a published row in the listing and never reaches
# it here — the prefix is the caller's own, so the lookup cannot name
# another instance's row. Shared by the definitions door and the named
# row's memory door.
module AgentAPI::V1::Profiles::NamedDefinitions
  extend ActiveSupport::Concern

  private

    def acting_user = current_credential.user

    def require_agent
      render_refusal(:not_agent) unless acting_user.agent_member?
    end

    def composed_identifier(name) =
      "#{acting_user.agent_identifier}#{User::NamedDefinition::DEFINITION_SEPARATOR}#{name}"

    # The caller's own active rows of either scope.
    def own_definitions
      User.where(derived_from_id: acting_user.id, status: :active).where.not(definition_scope: nil)
    end
end
