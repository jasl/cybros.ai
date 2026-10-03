module Rho
  class Core
    # Database memory through the conversation's logical path bindings. Each
    # primitive uses the same daemon route for terminal, browser and IM callers.
    module Memory
      def memory_list(public_id, path: nil, workspace_public_id: nil)
        query = { public_id: public_id, path: path, workspace_public_id: workspace_public_id }.compact
        response = get(require_daemon, "/conversations/memory?#{URI.encode_www_form(query)}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to list memory") unless response.code.to_i == 200

        document.fetch("memory")
      end

      def memory_read(public_id, path:, workspace_public_id: nil)
        memory_request(public_id, "read", { path: path }, workspace_public_id: workspace_public_id).fetch("memory")
      end

      def memory_write(public_id, path:, content:, expected_public_id:, expected_lock_version:, workspace_public_id: nil)
        memory_request(public_id, "write", { path: path, content: content,
          expected_public_id: expected_public_id, expected_lock_version: expected_lock_version },
          workspace_public_id: workspace_public_id).fetch("memory")
      end

      def memory_edit(public_id, path:, old_text:, new_text:, expected_public_id:, expected_lock_version:, workspace_public_id: nil)
        memory_request(public_id, "edit", { path: path, old_text: old_text, new_text: new_text,
          expected_public_id: expected_public_id, expected_lock_version: expected_lock_version },
          workspace_public_id: workspace_public_id).fetch("memory")
      end

      def memory_delete(public_id, path:, expected_public_id:, expected_lock_version:, workspace_public_id: nil)
        memory_request(public_id, "delete", { path: path,
          expected_public_id: expected_public_id, expected_lock_version: expected_lock_version },
          workspace_public_id: workspace_public_id).fetch("deleted")
      end

      def memory_grep(public_id, pattern:, path: nil, ignore_case: false, limit: nil, workspace_public_id: nil)
        memory_request(public_id, "grep", { pattern: pattern, path: path, ignore_case: ignore_case, limit: limit }.compact,
          workspace_public_id: workspace_public_id).fetch("result")
      end

      def bind_memory_context(public_id, memory_context:, workspace_public_id: nil)
        body = { public_id: public_id, memory_context: memory_context }
        body[:workspace_public_id] = workspace_public_id if workspace_public_id
        response = post(require_daemon, "/conversations/memory_context", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to bind memory") unless response.code.to_i == 200

        document.fetch("conversation")
      end

      private

        def memory_request(public_id, operation, fields, workspace_public_id:)
          body = fields.merge(public_id: public_id)
          body[:workspace_public_id] = workspace_public_id if workspace_public_id
          response = post(require_daemon, "/conversations/memory/#{operation}", body, budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          refuse(response, document, "the daemon refused to #{operation} memory") unless [200, 201].include?(response.code.to_i)

          document
        end
    end
  end
end
