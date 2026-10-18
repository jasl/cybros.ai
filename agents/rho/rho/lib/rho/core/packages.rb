module Rho
  class Core
    module Packages
      def packages
        response = get(require_daemon, "/extensions/packages")
        document = parse(response)
        refuse(response, document, "the daemon refused to list extension packages") unless response.code.to_i == 200

        document
      end

      def manage_package(action:, name: nil, version: nil, path: nil, configuration: nil)
        body = { action: action, name: name, version: version, path: path, configuration: configuration }.compact
        response = post(require_daemon, "/extensions/packages", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to manage the extension package") unless response.code.to_i == 200

        document
      end
    end
  end
end
