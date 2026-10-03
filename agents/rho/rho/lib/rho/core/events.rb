module Rho
  class Core
    # The durable page stays in the SDK's shape so surfaces can use its
    # KernelFeed for ordered replay without maintaining another cursor loop.
    module Events
      include CybrosAgent::Api::EventProjections

      def host_events(public_id, after: nil, limit: nil, workspace_public_id: nil)
        query = URI.encode_www_form({ "public_id" => public_id, "after" => after, "limit" => limit, "workspace_public_id" => workspace_public_id }.compact)
        response = get(require_daemon, "/loops/events?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the host's events") unless response.code.to_i == 200

        shape(CybrosAgent::Api::ConversationEventPage, document)
      end
    end
  end
end
