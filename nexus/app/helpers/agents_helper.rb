module AgentsHelper
  def agent_configuration_choice(field, value)
    return t("agent_resources.not_declared") if value.blank?

    t("agent_resources.configuration.#{field}.#{value}")
  end

  def agent_memory_limit(limit)
    return t("agent_resources.configuration.no_memory_limit") if limit.nil?

    bindings = MemoryContext.from_h(limit).bindings
    return t("agent_resources.none") if bindings.empty?

    bindings.map do |binding|
      t("agent_resources.configuration.memory_binding", scope: binding.scope,
        access: t("agent_resources.configuration.memory_access.#{binding.access}"))
    end.join(", ")
  end

  def agent_connection_presence(connection)
    case connection.fetch(:presence)
    when "online" then t("executors.presence.online")
    when "offline" then t("executors.presence.offline", time: time_ago_in_words(connection.fetch(:last_seen_at)))
    else t("executors.presence.not_seen")
    end
  end
end
