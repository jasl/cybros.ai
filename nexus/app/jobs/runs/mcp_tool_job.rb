# Duplicate delivery is safe: the Task owns one external start per generation.
class Runs::McpToolJob < ApplicationJob
  def perform(node_id, execution_generation)
    Runs::Mcp::Execute.call(node_id: node_id, execution_generation: execution_generation)
  end
end
