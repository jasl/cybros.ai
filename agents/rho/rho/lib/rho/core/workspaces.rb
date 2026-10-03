module Rho
  class Core
    module Workspaces
      def workspaces
        response = get(require_daemon, "/workspaces", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to list workspaces") unless response.code == "200"
        document
      end

      def workspace(public_id)
        query = URI.encode_www_form("public_id" => public_id)
        response = get(require_daemon, "/workspaces/detail?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused the workspace") unless response.code == "200"
        document.fetch("workspace")
      end

      def create_workspace(name:, idempotency_key: nil)
        body = { "name" => name, "idempotency_key" => idempotency_key || SecureRandom.uuid }
        response = post(require_daemon, "/workspaces", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to create the workspace") unless response.code == "201"
        document.fetch("workspace")
      end

      # The operator's settings belong to this client process, as runner selection does.
      def select_workspace(public_id)
        response = post(require_daemon, "/workspaces/select", { "public_id" => public_id }, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused the workspace selection") unless response.code == "200"
        row = document.fetch("workspace")
        @home.write_setting("workspace", row.fetch("public_id"))
        row
      end
    end
  end
end
