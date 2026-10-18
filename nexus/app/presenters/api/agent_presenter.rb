module API
  class AgentPresenter
    def self.full(agent)
      address = Executor.application_address_for(agent) if agent.execution_principal_eligible?
      connection = if address
        application_connection(address,
          credential_readiness: Executor.credential_readiness_for([address]).fetch(address.id),
          live_server_ids: NexusServer.live_ids)
      end
      basic(agent).merge(application_connection: connection)
    end

    def self.basic(agent)
      {
        public_id: agent.public_id,
        handle: agent.handle,
        display_name: agent.display_name,
        status: agent.status,
        agent_identifier: agent.agent_identifier,
        named_agent_scope: agent.named_agent_scope,
        description: agent.description,
        derived_from_public_id: agent.derived_from&.public_id,
      }
    end

    def self.configuration(agent, measured_at:)
      documents = agent.prompt_documents.select { |document| %w[system_prompt summarizer].include?(document.slot) }
      {
        agent: basic(agent),
        configuration: AgentAPI::ProfilePresenter.configuration(agent),
        prompt_documents: documents.sort_by(&:slot).map { |document| AgentAPI::PromptDocumentPresenter.full(document) },
        agent_updated_at: agent.updated_at,
        measured_at: measured_at,
      }
    end

    def self.application_connection(address, credential_readiness:, live_server_ids:)
      {
        executor_public_id: address.public_id,
        owner_agent_public_id: address.agent.public_id,
        status: address.status,
        credential_readiness: credential_readiness,
        presence: Nexus::Presence.of(address, live_server_ids: live_server_ids),
        last_seen_at: address.last_seen_at,
        connected_at: address.connected_at,
      }
    end
  end
end
