class AgentAPI::V1::Profiles::MemoryCollectionsController < AgentAPI::V1::MemoryCollections::OwnedController
  private

    def owner = acting_user
    def owner_scope = owner.human? ? :user : :agent
end
