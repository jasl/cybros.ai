module Executors
  module TaskOperations
    # The result and its replay identity share the task's settlement transaction.
    # Accepted child operations must be observed or explicitly released before
    # success; the same operation facts bound which captures a final may retain.
    class Finalization
      Result = AgentRuns::Parks::Settle::Result

      def initialize(command:, node:)
        @command = command
        @node = node
      end

      def call
        final_digest = digest
        @command.agent_run.with_lock do
          node = @command.agent_run.agent_run_tasks.find_by(id: @node.id)
          next Result.refused(:not_found) if node.nil? || @command.agent_run.tombstoned?
          # Check ownership under the same lock as operation acceptance. A
          # plain tool keeps ordinary settlement, while a concurrently accepted
          # child cannot escape the operation owner's finalization rules.
          next yield(node, nil) unless node.operation_owner?
          next Result.refused(:stale_claim, node) unless node.claimed_by?(@command.executor, token: @command.claim_token)

          if node.committed_result_digest
            next Result.refused(:result_unstorable, node) if final_digest.nil?

            next node.committed_result_digest == final_digest ? Result.idle(node) : Result.refused(:final_result_conflict, node)
          end
          next Result.refused(:task_not_running, node) unless node.status == "dispatched"
          # Final output reconciles an existing claim, including one draining
          # through graceful Stop or pause. New operations remain running-only.
          next Result.refused(:execution_stopped, node) if AgentRuns::SourceWork.execution_stopped?(@command.agent_run)
          now = @command.agent_run.effective_now(DatabaseClock.now)
          if @command.outcome != "failed" && !node.deadline_passed?(now) && pending_children?(node)
            next Result.refused(:pending_children, node)
          end

          result = yield(node, retained_upload_ids(node))
          if result.applied? && final_digest && %w[completed failed].include?(node.status)
            node.update!(committed_result_digest: final_digest)
          end
          result
        end
      end

      private

        def digest
          Nexus::CanonicalJson.digest({
            "content" => @command.content,
            "structured_content" => @command.structured_content,
            "structured_content_present" => @command.structured_content_present,
            "result_type" => @command.result_type || AgentRuns::Parks::ResultContent::DEFAULT_RESULT_TYPE,
            "outcome" => @command.outcome || "completed", "is_error" => @command.is_error,
            "title" => @command.title, "metadata" => @command.metadata,
          })
        rescue Nexus::CanonicalJson::UnsupportedValue
          # Settle owns unstorable-result closure. Such bytes cannot become an
          # accepted final identity merely because the task reached failure.
          nil
        end

        def pending_children?(node)
          operations = node.task_operations.to_a
          return false if operations.empty?

          released = operations.flat_map { |operation| operation.response.dig("receipt", "released_operations") || [] }.to_set
          unobserved = operations.any? do |operation|
            operation.observed_position.nil? && !operation.response.dig("receipt", "background") &&
              !released.include?(operation.operation_key)
          end
          unobserved || AgentRuns::TaskOperations.attached_children(node).any? { |child| !child.terminal? }
        end

        def retained_upload_ids(node)
          ContentBodyUpload.joins(content_body: :agent_run_task_operation)
            .where(agent_run_task_operations: { agent_run_task_id: node.id })
            .select(:content_upload_id)
        end
    end
  end
end
