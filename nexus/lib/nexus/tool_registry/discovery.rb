module Nexus
  module ToolRegistry
    module Discovery
      TOOLS = [
        Tool.new(
          canonical: "nexus.tools.search", name: "tool_search",
          template: <<~TEXT.strip,
            Search this execution's available tools and skills. Search by exact callable name,
            task words, or Runner UUID and tool name. Results include the exact callable name,
            full input schema, Runner target when present, and matching skill summaries.
            Use {{tool_call}} with a returned name and schema to invoke a tool. Search does not
            change which tools this execution may use. Refine the query when results are truncated.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "query" => { "type" => "string", "description" => "An exact callable name or search words." },
              "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 20,
                           "description" => "Maximum tools to return; defaults to 5." },
            },
            "required" => ["query"],
          },
          effect_profile: READ_ONLY_CLOSED,
          executor: "AgentRuns::ToolDiscovery::Search", job: "AgentRuns::ToolDiscoveryJob",
        ),
        Tool.new(
          canonical: "nexus.tools.call", name: "tool_call",
          template: <<~TEXT.strip,
            Invoke one tool available to this execution using its exact callable name and input
            schema from {{tool_search}}. The call waits for that tool's result and retains its
            declared Runner target and ordinary approval requirements. A name never grants access
            to a tool outside this execution's declaration.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "name" => { "type" => "string", "description" => "The exact callable name returned by {{tool_search}}." },
              "input" => { "type" => "object", "description" => "The tool's arguments, following its returned schema." },
            },
            "required" => %w[name input],
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentRuns::ToolDiscovery::Call", job: "AgentRuns::ToolDiscoveryJob",
        ),
      ].freeze
    end
  end
end
