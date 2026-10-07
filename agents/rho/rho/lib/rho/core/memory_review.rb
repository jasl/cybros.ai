module Rho
  class Core
    module MemoryReview
      def memory_review(public_id, workspace_public_id: nil)
        query = URI.encode_www_form({ public_id: public_id, workspace_public_id: workspace_public_id }.compact)
        response = get(require_daemon, "/conversations/memory_review?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read memory review settings") unless response.code.to_i == 200

        document.fetch("memory_review")
      end

      def enable_memory_review(public_id, path:, model: nil, workspace_public_id: nil)
        memory_review_change("enable", public_id, { path: path, model: model }, workspace_public_id: workspace_public_id)
      end

      def disable_memory_review(public_id, workspace_public_id: nil)
        memory_review_change("disable", public_id, {}, workspace_public_id: workspace_public_id)
      end

      def resume_memory_review(public_id, workspace_public_id: nil)
        memory_review_change("resume", public_id, {}, workspace_public_id: workspace_public_id)
      end

      private

        def memory_review_change(operation, public_id, fields, workspace_public_id:)
          body = fields.merge(public_id: public_id, workspace_public_id: workspace_public_id).compact
          response = post(require_daemon, "/conversations/memory_review/#{operation}", body, budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          refuse(response, document, "the daemon refused to change memory review settings") unless response.code.to_i == 200

          document.fetch("memory_review")
        end
    end
  end
end
