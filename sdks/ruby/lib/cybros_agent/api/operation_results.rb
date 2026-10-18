module CybrosAgent
  module Api
    # Frozen declarations and model defaults belong to this execution, so
    # nested operations do not consult a changed live announcement.
    OperationContext = Data.define(:tools, :model_defaults, :environment) do
      def initialize(environment: nil, **) = super
    end

    OperationRefusal = Data.define(:code, :message)

    # The trace orders accepted requests and the outcomes actually observed.
    # Requests, receipts and outcome payloads retain the kernel's JSON whole;
    # this transport layer does not interpret a language or tool's values.
    OperationEvent = Data.define(:type, :position, :key, :request, :receipt, :outcome, :refusal) do
      def initialize(request: nil, receipt: nil, outcome: nil, refusal: nil, **members)
        super(request: request, receipt: receipt, outcome: outcome, refusal: refusal, **members)
      end

      def operation? = type == "operation"
      def observation? = type == "observation"
      def refused? = !refusal.nil?
      def to_h
        fields = { type: type, position: position, key: key }
        fields[:request] = request if operation?
        if refused?
          fields[:refusal] = refusal.to_h
        elsif operation?
          fields[:receipt] = receipt
        else
          fields[:outcome] = outcome
        end
        fields
      end
    end

    TaskOperations = Data.define(:context, :trace, :position, :next_after) do
      def initialize(next_after: nil, **members)
        super(next_after: next_after, **members)
      end
    end

    # A null observation means nothing is ready. It says nothing about a
    # child's success or whether an unknown external effect can be repeated.
    OperationRead = Data.define(:observation, :position) do
      def waiting? = observation.nil?
    end
  end
end
