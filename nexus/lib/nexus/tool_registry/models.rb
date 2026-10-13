module Nexus
  module ToolRegistry
    module Models
      TOOLS = [
        Tool.new(
          canonical: "nexus.models.list", name: "models_list",
          template: <<~TEXT.strip,
            List models currently available to this account, with exact provider/model references,
            model identities, capabilities and pricing. Query optionally matches a reference,
            provider or model name without regard to case. Results are ordered by reference.
            Use limit and offset to page through matches; next_offset is null on the last page.
            Availability is current catalog and credential state, not a provider connection test.
          TEXT
          parameters: { "type" => "object", "properties" => {
            "query" => { "type" => "string", "description" => "Optional case-insensitive substring." },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 20 },
            "offset" => { "type" => "integer", "minimum" => 0, "default" => 0 },
          }, "additionalProperties" => false },
          effect_profile: READ_ONLY_CLOSED,
          executor: "AgentRuns::Models::List", job: "AgentRuns::ToolDiscoveryJob",
        ),
      ].freeze
    end
  end
end
