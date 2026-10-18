module SimpleInference
  module Responses
    # The provider's own words beside a declined finish (FinishQuality::
    # DECLINED): the category in the provider's vocabulary and its sentence,
    # each carried verbatim and each nullable — a provider may name no
    # category (a normal, permanent value) or send no sentence, and nothing
    # is invented in their place. The sentence is display text, never parsed.
    # A blank word is the absence the wire meant.
    Refusal = Data.define(:category, :explanation) do
      # A lane's refusal, present exactly when its finish is a decline
      # under the lane's own FinishQuality table.
      def self.for_finish(table, finish_detail, category: nil, explanation: nil)
        return nil unless FinishQuality.declined?(table, finish_detail)

        new(category:, explanation:)
      end

      def initialize(category: nil, explanation: nil)
        super(
          category: category.to_s.empty? ? nil : category.to_s,
          explanation: explanation.to_s.empty? ? nil : explanation.to_s,
        )
      end
    end

    class Refusal
      # What a provider's category word means, where the word alone does
      # not say it plainly — display text a reader gets BESIDE the verbatim
      # word, never in its place and never a decision input. Anthropic's
      # words are its refusal categories; the upper-case words are Gemini's
      # finish and prompt-block reasons this gem types as a decline.
      MEANINGS = {
        "reasoning_extraction" => "the request asks for the model's own reasoning",
        "frontier_llm" => "it could aid building competing AI models",
        "LANGUAGE" => "an unsupported language",
        "RECITATION" => "the answer would recite a source",
        "IMAGE_RECITATION" => "the answer would recite a source",
        "SPII" => "sensitive personal data",
        "BLOCKLIST" => "a blocklisted term",
      }.freeze
    end

    # A value object over a completed generation. Protocol parsers own payload
    # normalization; Result keeps those canonical values without walking and
    # copying the completed response a second time.
    #
    # `finish_detail` is the lane's TYPED FINISH FACT, which `finish_reason`
    # is not on every lane: on the Responses family that member is the
    # response's lifecycle STATUS ("completed"/"incomplete") while the reason
    # the answer stopped lives in `incomplete_details.reason`. It is the value
    # `FinishQuality` consumes, and it is REQUIRED so a lane that forgets it
    # fails at construction instead of reporting every cut-off answer as a
    # clean finish (Round E review); pass nil for a lane with no finish concept.
    #
    # `refusal` is the typed Refusal beside a declined finish and nil on
    # every other; the raw body stays on `provider_response`. A refusal's
    # text is never part of `output_text`: the refusal is not the answer.
    Result = Data.define(
      :id, :output_text, :output_items, :tool_calls, :assistant_message,
      :usage, :finish_reason, :finish_detail, :refusal, :provider_response, :provider_format
    ) do
      def initialize(output_text:, output_items:, tool_calls:, usage:, finish_reason:,
                     finish_detail:, provider_response:, provider_format:,
                     id: nil, assistant_message: {}, refusal: nil)
        super(
          id:, output_text: output_text.to_s, output_items:, tool_calls:, assistant_message:,
          usage:, finish_reason:, finish_detail:, refusal:, provider_response:, provider_format:,
        )
      end

      def self.from_openai_responses(result)
        response = result.response
        body = response&.body || {}
        refusal_parts = refusal_parts_from_output_items(result.output_items)
        # The status says only THAT the answer stopped early; the reason says
        # why. A completed response whose message is a refusal part has no
        # reason at all, so the refusal is typed here.
        finish_detail = result.incomplete_reason || ("refusal" if refusal_parts.any?)
        explanation = refusal_parts.map { |part| part["refusal"].to_s }.join

        new(
          id: body["id"],
          output_text: result.output_text,
          output_items: result.output_items,
          tool_calls: tool_calls_from_output_items(result.output_items),
          assistant_message: {},
          usage: result.usage,
          finish_reason: body["status"] || body["finish_reason"],
          finish_detail: finish_detail,
          refusal: Refusal.for_finish(FinishQuality::RESPONSES, finish_detail, explanation:),
          provider_response: response,
          provider_format: "responses"
        )
      end

      def self.from_openai_chat(result)
        response = result.response
        body = response&.body || {}
        assistant_message = body.dig("choices", 0, "message") || {}
        explanation = assistant_message["refusal"].to_s
        # On this wire the finish reason IS the typed verdict — except that a
        # refusal message ends "stop" like any answer, so it is typed here.
        finish_detail =
          if explanation.empty? || result.finish_reason != "stop"
            result.finish_reason
          else
            "refusal"
          end

        new(
          id: body["id"],
          output_text: result.content,
          output_items: [],
          tool_calls: Array(assistant_message["tool_calls"]),
          assistant_message: assistant_message,
          usage: result.usage,
          finish_reason: result.finish_reason,
          finish_detail: finish_detail,
          refusal: Refusal.for_finish(FinishQuality::CHAT, finish_detail, explanation:),
          provider_response: response,
          provider_format: "chat_completions"
        )
      end

      def self.tool_calls_from_output_items(output_items)
        Array(output_items).select { |item| item["type"].to_s == "function_call" }
      end

      def self.refusal_parts_from_output_items(output_items)
        Array(output_items).flat_map do |item|
          Array(item["content"]).select { |part| part["type"].to_s == "refusal" }
        end
      end
      private_class_method :refusal_parts_from_output_items
    end
  end
end
