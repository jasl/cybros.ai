module Nexus
  module ToolRegistry
    module Runners
      TOOLS = [
        Tool.new(
          canonical: "nexus.runners.list", name: "runners_list",
          template: <<~TEXT.strip,
            List this execution's declared candidate Runner environments and its current Runner UUID.
            Each candidate includes its UUID, display name and declared environment facts.
            To start a conversation in another candidate environment, pass its UUID to {{spawn}}.
            Omitting the Runner on {{spawn}} inherits the current environment; null selects none.
            The list is frozen when this work is accepted. It does not import tools or change the
            environment of accepted work, and does not promise that a Runner is currently connected.
          TEXT
          parameters: { "type" => "object", "properties" => {}, "additionalProperties" => false },
          effect_profile: READ_ONLY_CLOSED,
          executor: "AgentRuns::Runners::List", job: "AgentRuns::ToolDiscoveryJob",
        ),
      ].freeze
    end
  end
end
