module Rho
  # Application policy only: the executor remains available to resume work.
  module CodeMode
    module_function

    def valid?(value) = [nil, true, false].include?(value)
    def enabled?(config, override = nil)
      config.plugin_enabled?("rho.codemode") && (override.nil? ? config.plugin_configuration("rho.codemode").fetch("default") == "on" : override)
    end
    def tools(entries, enabled) = enabled ? entries : entries.reject { |entry| code?(entry) }
    def code?(entry) = (entry.dig("route", "tool_name") || entry.dig("function", "name")) == "code"
    def names(names, enabled, code_names:) = enabled ? names : names - code_names
  end
end
