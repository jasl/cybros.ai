module CybrosAgent
  module Api
    # Operations on one active claim. These requests never retry implicitly:
    # the consumer reconciles an unknown result through its stable identity
    # and the durable trace before deciding how to proceed.
    module ExecutorTaskOperations
      include OperationProjections

      def operations(claim_token:, after: nil, limit: nil)
        headers = { "Claim-Token" => required_string(claim_token, "claim_token") }
        params = query(
          after: after.nil? ? nil : operation_integer(after, "after", minimum: 0),
          limit: limit.nil? ? nil : operation_integer(limit, "limit", minimum: 1)
        )
        shape(TaskOperations, @dispatch.call("#{path}/operations", headers: headers, params: params), "operations")
      end

      def submit(claim_token:, key:, request:)
        body = {
          "claim_token" => required_string(claim_token, "claim_token"),
          "operation" => { "key" => required_string(key, "key"), "request" => request.to_h },
        }
        shape(OperationEvent,
          @dispatch.call("#{path}/operations", method: :post, body: body, success: [200, 201]), "operation")
      end

      def observe(claim_token:, after:)
        body = operation_position(claim_token, after)
        shape(OperationRead, @dispatch.call("#{path}/observation", method: :post, body: body))
      end

      private

        def operation_position(claim_token, after)
          { "claim_token" => required_string(claim_token, "claim_token"),
            "after" => operation_integer(after, "after", minimum: 0) }
        end

        def operation_integer(value, name, minimum:)
          integer = Integer.try_convert(value)
          return integer if integer && integer >= minimum && integer.eql?(value)

          raise ArgumentError, "#{name} must be an Integer at least #{minimum}"
        end
    end
  end
end
