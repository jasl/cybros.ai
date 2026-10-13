module SimpleInference
  module Responses
    # The sealed event vocabulary a Responses::Stream yields; `type` is the
    # OpenAI Responses spelling every consumer already matches on.
    module Events
      TextDelta = Data.define(:delta) do
        def initialize(delta:) = super(delta: delta.to_s)

        def type = "response.output_text.delta"
      end

      ReasoningDelta = Data.define(:delta, :kind, :item_id) do
        def initialize(delta:, kind: "reasoning_text", item_id: nil) = super(delta: delta.to_s, kind: kind.to_s, item_id:)

        def type = "response.reasoning.delta"
      end

      ToolCallDelta = Data.define(:item_id, :call_id, :name, :delta) do
        def initialize(item_id:, delta:, call_id: nil, name: nil) = super(item_id:, call_id:, name:, delta: delta.to_s)

        def type = "response.function_call_arguments.delta"
      end

      ToolCallDone = Data.define(:item_id, :call_id, :name, :arguments) do
        def initialize(item_id:, arguments:, call_id: nil, name: nil) = super(item_id:, call_id:, name:, arguments: arguments.to_s)

        def type = "response.function_call_arguments.done"
      end

      Completed = Data.define(:result) do
        def type = "response.completed"
      end
    end

    class Stream
      include Enumerable

      def initialize(&producer)
        @producer = producer
        @started = false
        @completed = false
        @text = +""
        @final_result = nil
      end

      def each
        return enum_for(:each) unless block_given?
        raise SimpleInference::StreamError, "Responses::Stream can only be consumed once" if @started

        @started = true
        @final_result =
          @producer.call do |event|
            case event
            when Events::TextDelta then @text << event.delta
            when Events::Completed then @final_result = event.result
            else nil
            end

            yield event
          end
        # Reached only when the producer ran to completion — a non-local exit
        # (break in the consumer's block, or an exception) skips this line,
        # which is exactly what marks the stream INTERRUPTED.
        @completed = true
        @final_result
      end

      # The accumulated text so far — the final result's canonical output_text
      # once the stream completed. Unlike #final_result this stays readable
      # after an interruption: partial text is real information on abort paths.
      def output_text
        until_done
        return @final_result.output_text if @final_result

        @text.dup
      end
      alias text output_text

      # The final Result. Self-consumes an untouched stream; raises on an
      # INTERRUPTED one — an abort path must never read as "completed with no
      # result".
      def final_result
        until_done
        if @started && !@completed
          raise SimpleInference::StreamError,
                "the stream was interrupted before completion — no final result is available"
        end

        @final_result
      end

      private

      def until_done
        each { |_event| nil } unless @started
        @final_result
      end
    end
  end
end
