class AgentAPI::V1::Profiles::Agents::MemoryCollectionsController < AgentAPI::V1::Profiles::MemoryCollectionsController
  include AgentAPI::V1::Profiles::NamedAgents
  before_action :require_agent

  private

    def owner
      @owner ||= own_definitions.where(steward_id: acting_user.steward_id)
        .find_by!(agent_identifier: composed_identifier(params.fetch(:agent_name)))
    end
end
