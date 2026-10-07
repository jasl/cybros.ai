module Rho
  module Mcp
    module Refresh
      module_function

      def call(request, context)
        name = Rho::ControlServer.json_body(request).fetch("name").to_s
        entry = Mcp.entries[name]
        return Rho::Daemon::Refusal.malformed("Name a configured MCP server") if entry.nil?

        outcome = context.refresh_extension(NAME)
        return outcome if outcome in Rho::Daemon::Refusal

        server = Mcp.report.fetch("servers").find { |row| row.fetch("key") == name && !row.key?("owner") }
        [200, outcome.merge("server" => server)]
      rescue KeyError => error
        Rho::Daemon::Refusal.parameter_missing(error.key)
      end
    end
  end
end
