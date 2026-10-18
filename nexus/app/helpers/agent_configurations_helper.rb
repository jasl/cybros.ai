module AgentConfigurationsHelper
  def current_agent_configuration_link(answerer, **html_options)
    if answerer&.agent_member? && answerer.steward_id == Current.user.id
      link_to t("configuration_iteration.current_configuration"), agent_configuration_path(answerer), **html_options
    end
  end
end
