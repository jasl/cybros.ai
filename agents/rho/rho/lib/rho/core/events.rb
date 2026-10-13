module Rho
  class Core
    # The durable page stays in the SDK's shape so surfaces can use its
    # KernelFeed for ordered replay without maintaining another cursor loop.
    module Events
      include CybrosAgent::Api::ConversationProjections

      def host_events(public_id, after: nil, limit: nil, workspace_public_id: nil)
        query = URI.encode_www_form({ "public_id" => public_id, "after" => after, "limit" => limit, "workspace_public_id" => workspace_public_id }.compact)
        response = get(require_daemon, "/runs/events?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the host's events") unless response.code.to_i == 200

        shape(CybrosAgent::Api::ConversationEventPage, document)
      end

      # The original execution behind an accepted input; nil means the
      # kernel has no retained readable materialization, never a later reply.
      def input_materialization(public_id, input_public_id:, workspace_public_id: nil)
        query = URI.encode_www_form({ "public_id" => public_id, "input_public_id" => input_public_id,
          "workspace_public_id" => workspace_public_id }.compact)
        response = get(require_daemon, "/conversations/input_materialization?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the input's materialization") unless response.code.to_i == 200

        optional_shape(CybrosAgent::Api::InputMaterialization, document, "materialization")
      end
    end
  end
end
