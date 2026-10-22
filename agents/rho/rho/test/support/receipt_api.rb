require "support/nexus_doubles"

module RhoTest
  # The kernel owns receipts, scoped to the acting credential and door. This
  # transport double can lose a response AFTER accepting the input, so a retry
  # through Core, the daemon and the real SDK must carry the same key and body.
  class ReceiptApi < NexusDoubles::FakeAgentApi
    attr_reader :writes

    def initialize(lose_input_response: false, lose_create_response: false, before_input: nil, **options)
      super(trace: NexusDoubles::RUNNING_TRACE, **options)
      @receipts = {}
      @writes = []
      @lose_input_response = lose_input_response
      @lose_create_response = lose_create_response
      @before_input = before_input
    end

    def call(path, method: :get, credential: nil, body: nil, headers: {}, **options)
      return super unless method == :post && path.match?(%r{/(conversations|inputs)\z})

      key = headers.fetch("Idempotency-Key")
      @writes << [path, key]
      scope = [credential, path, key]
      @before_input&.call if path.end_with?("/inputs")
      if (receipt = @receipts[scope])
        previous, response = receipt
        raise CybrosAgent::Api::Conflict.new("The request changed", code: "idempotency_envelope_mismatch") if previous != body

        return response.with(headers: response.headers.merge("Idempotency-Replayed" => "true"))
      end

      response = super
      @receipts[scope] = [JSON.parse(JSON.generate(body)), response]
      if path.end_with?("/conversations") && @lose_create_response
        @lose_create_response = false
        raise CybrosAgent::TransportError, "The accepted conversation response was lost"
      end
      if path.end_with?("/inputs") && @lose_input_response
        @lose_input_response = false
        raise CybrosAgent::TransportError, "The accepted input response was lost"
      end
      response
    end
  end
end
