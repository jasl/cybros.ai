module API::V1::AgentReading
  private

  # Human inspection includes named identities. Credential and connection
  # commands keep their narrower independent-Agent finder.
  def readable_agents
    Current.user.stewarded_agents.includes(:derived_from)
  end

  def load_readable_agent
    @agent = readable_agents.find_by!(public_id: params[:agent_id] || params[:id])
  end
end
