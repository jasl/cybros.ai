module SimpleInference
  module Protocols
    class GeminiGenerateContent
      # The fold over one generateContent stream: output items under
      # assembly, the latest usage snapshot (each chunk REPLACES the previous
      # one — the last seen is authoritative, and survives a bare terminal
      # chunk), prompt feedback, and the terminal finishReason.
      class StreamFold
        attr_accessor :output_items, :latest_usage_metadata, :prompt_feedback, :finish_reason
        attr_reader :events_seen

        def initialize
          @output_items = []
          @latest_usage_metadata = nil
          @prompt_feedback = {}
          @finish_reason = nil
          @events_seen = 0
        end

        def count_event = @events_seen += 1
      end
    end
  end
end
