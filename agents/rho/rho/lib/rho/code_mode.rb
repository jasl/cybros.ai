module Rho
  # Application policy only: the executor remains available to resume work.
  module CodeMode
    module_function

    def valid?(value) = [true, false].include?(value)
    def enabled?(config, override = nil)
      config.plugin_enabled?("rho.codemode") && (override.nil? ? config.plugin_configuration("rho.codemode").fetch("default") == "on" : override)
    end
    def tools(entries, enabled) = enabled ? entries : entries.reject { |entry| code?(entry) }
    # An MCP server's remote spelling does not identify rho's code facade.
    def code?(entry) = entry.dig("route", "kind") != "mcp" && (entry.dig("route", "tool_name") || entry.dig("function", "name")) == "code"
  end
end
