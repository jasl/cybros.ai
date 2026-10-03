module Nexus
  # `compose` — the graph-authoring tool: a model answers a round with a pure
  # function that builds a subgraph. The script awaits nothing and invokes no
  # model; it returns tasks the kernel appends, so the kernel stays the only driver.
  module Compose
    TOOL_NAME = "compose".freeze

    # Published from the registry so every client sends the same bytes: the
    # tools block is the front of the cached prefix. The agent declares it per
    # model task like any other tool; nexus holds no notion of a mode.
    DEFINITION = ToolRegistry.function_definition(TOOL_NAME)
  end
end
