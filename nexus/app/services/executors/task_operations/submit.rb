module Executors
  module TaskOperations
    class Submit
      KEY_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/

      def initialize(access:, key:, request:)
        @access = access
        @key = key.to_s
        @request = Hash.try_convert(request)
      end

      def call
        return Outcome.refused(:invalid_operation_key) unless @key.match?(KEY_FORMAT)
        return Outcome.refused(:invalid_operation) if @request.nil? || @request["kind"].blank?
        return Outcome.refused(:operation_too_large) unless Nexus::SizeBounds.json_within?(:envelope_bound, @request)

        @access.mutate do |node|
          existing = node.task_operations.find_by(operation_key: @key)
          if existing
            next Outcome.refused(:operation_mismatch) unless existing.request_digest == digest

            next Outcome.accepted({ "operation" => Trace.operation(existing), "created" => false })
          end
          response = apply(node)
          record = node.task_operations.create!(operation_key: @key, kind: @request.fetch("kind", "").to_s,
            request_digest: digest, request: @request, response: response, position: Trace.position(node) + 1)
          AgentRuns::ScheduleJob.perform_later(node.agent_run_id)
          Outcome.accepted({ "operation" => Trace.operation(record), "created" => true })
        end
      rescue Nexus::CanonicalJson::UnsupportedValue
        Outcome.refused(:invalid_operation)
      end

      private

        def digest = @digest ||= Nexus::CanonicalJson.digest(@request)

        def apply(node)
          AgentRunTaskOperation.transaction(requires_new: true) do
            Work.new(node: node, request: @request).call
          end
        rescue Lower::Refusal => error
          { "refusal" => { "code" => error.code.to_s, "message" => error.message } }
        rescue AgentRuns::Tasks::Step::Refusal => error
          { "refusal" => { "code" => error.refused.code, "message" => error.message } }
        end
    end
  end
end
