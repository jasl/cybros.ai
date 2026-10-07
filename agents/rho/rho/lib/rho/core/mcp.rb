module Rho
  class Core
    module Mcp
      def refresh_mcp(name)
        response = post(require_daemon, "/mcp/refresh", { "name" => name }, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to refresh MCP") unless response.code.to_i == 200

        document
      end
    end
  end
end
