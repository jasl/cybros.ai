require "cybros_agent"

module Rho
  # Transport adapters for the SDK observer. Waiting and interaction remain
  # with each surface; Core keeps one named primitive per local route.
  class InputExecution
    include CybrosAgent::Api::ConversationProjections

    def initialize(core:, conversation:)
      @core = core
      @conversation = conversation
    end

    def for_input(input_public_id:, position:)
      CybrosAgent::InputExecution.new(input_public_id: input_public_id, position: position,
        materialization: ->(input) { @core.input_materialization(@conversation, input_public_id: input) }, **readers)
    end

    def for_execution(execution:)
      CybrosAgent::InputExecution.for_execution(execution: execution, **readers)
    end

    private

      def readers
        {
          replay: ->(cursor) { @core.host_events(@conversation, after: cursor) },
          variants: ->(turn) {
            shape(CybrosAgent::Api::VariantDeck,
              { "turn" => { "public_id" => turn }, "variants" => @core.variants(@conversation, turn) })
          },
          run: ->(public_id) { @core.run_state(public_id) },
        }
      end
  end
end
