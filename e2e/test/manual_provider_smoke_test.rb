$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "support/manual_provider"

class ManualProviderSmokeTest < Minitest::Test
  def test_one_openai_response_and_print_a_compact_capture
    E2E::ManualProvider.validate!
    model = E2E::ManualProvider.model
    client = E2E::ManualProvider.client
    stream = client.responses.stream(
      model: model,
      input: "Reply with the single word ping.",
      # Room for the default model's reasoning before its one word: GPT-6
      # thinks at medium unless told otherwise, and 32 tokens could end
      # `incomplete` with no text at all.
      max_output_tokens: 1024
    )
    text = +""
    usage = nil

    result = stream.each do |event|
      case event
      when SimpleInference::Responses::Events::TextDelta
        text << event.delta
      when SimpleInference::Responses::Events::Completed
        usage = event.result.usage
      else
        next
      end
    end

    refute_empty text
    puts JSON.generate(
      model: model, status: result.provider_response.status,
      text: text, usage: usage
    )
  end
end
