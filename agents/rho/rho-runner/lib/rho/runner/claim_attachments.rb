module Rho
  class Runner
    # A worker requests an input read; the pool's reactor wait performs it.
    # The worker never receives a client or a credential. Its IO remains
    # owned by the handler and is used only while the handler awaits this reply.
    class ClaimAttachments
      # Match the existing progress wait cadence for ordinary tool handlers.
      POLL_SECONDS = 0.25
      Request = Data.define(:public_id, :io, :answer)
      private_constant :Request

      def initialize(task:, claim_token:)
        @task = task
        @claim_token = claim_token
        @pending = Thread::Queue.new
      end

      def read(public_id, io)
        answer = Thread::Queue.new
        @pending << Request.new(public_id: public_id, io: io, answer: answer)
        loop do
          ExecutionContext.current&.raise_if_cancelled!
          result = answer.pop(timeout: POLL_SECONDS)
          next unless result
          raise result.fetch(:error) if result.key?(:error)

          return result.fetch(:upload)
        end
      end

      def wait = @pending.empty? ? POLL_SECONDS : 0

      def flush
        request = @pending.pop(timeout: 0)
        return unless request

        upload = @task.attachment(request.public_id, claim_token: @claim_token)
        @task.attachment_bytes(request.public_id, request.io, claim_token: @claim_token)
        request.answer << { upload: upload }
      rescue StandardError => error
        request.answer << { error: error }
      end
    end
  end
end
