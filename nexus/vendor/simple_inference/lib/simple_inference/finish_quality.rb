module SimpleInference
  # Maps each text protocol's typed finish detail to the finish qualities
  # Nexus persists. Unknown profiles and details are ordinary clean or
  # unclassified finishes and return nil.
  module FinishQuality
    OUTPUT_BUDGET_EXHAUSTED = "output_budget_exhausted".freeze
    CONTEXT_WINDOW_EXHAUSTED = "context_window_exhausted".freeze
    # A classifier declined the request or the answer: an HTTP 200 whose
    # finish says so, on every lane. The Result carries the provider's words
    # as `refusal`; another model may answer the same request.
    REFUSED = "refused".freeze
    # A content-protection stop on the CONTENT itself — prohibited content,
    # personal data, a customer's blocklist. The Result carries `refusal`
    # too; the content is never sent anywhere again, because no provider
    # invites resending what it stopped (Google's word is "rephrase").
    BLOCKED = "blocked".freeze
    # The exchange finished, but generation failed. This says nothing about
    # retryability or safety classification; consumers keep the usage and
    # fail the work without adopting partial output.
    ERROR = "error".freeze
    QUALITIES = [OUTPUT_BUDGET_EXHAUSTED, CONTEXT_WINDOW_EXHAUSTED, REFUSED, BLOCKED, ERROR].freeze
    # The provider declined. A lane attaches `Result#refusal` exactly when
    # its finish maps to one of these; a consumer branches on the word,
    # never on a category (each provider has its own vocabulary, or none).
    DECLINED = [REFUSED, BLOCKED].freeze

    # The Responses family's reason rides `incomplete_details.reason`; a
    # completed response whose message holds a refusal part is typed
    # "refusal" by the Result, since its status says only "completed".
    RESPONSES = {
      "max_output_tokens" => OUTPUT_BUDGET_EXHAUSTED,
      "content_filter" => REFUSED,
      "refusal" => REFUSED,
    }.freeze
    MESSAGES = {
      "max_tokens" => OUTPUT_BUDGET_EXHAUSTED,
      "model_context_window_exceeded" => CONTEXT_WINDOW_EXHAUSTED,
      "refusal" => REFUSED,
    }.freeze
    # The candidate's finishReason, or PROMPT_<blockReason> when the prompt
    # itself was blocked and no candidate exists. RECITATION is a verdict on
    # the ANSWER (it may recite a source) and LANGUAGE an empty candidate in
    # a language the model does not serve, so another model's answer is a
    # different answer: both refuse. Google's non-policy abnormal stops are
    # errors, including OTHER/IMAGE_OTHER whose cause is unknown. The enum
    # describes STOP alone as natural completion:
    # https://ai.google.dev/api/generate-content#FinishReason
    GEMINI = {
      "MAX_TOKENS" => OUTPUT_BUDGET_EXHAUSTED,
      "SAFETY" => REFUSED,
      "IMAGE_SAFETY" => REFUSED,
      "RECITATION" => REFUSED,
      "IMAGE_RECITATION" => REFUSED,
      "LANGUAGE" => REFUSED,
      "PROHIBITED_CONTENT" => BLOCKED,
      "IMAGE_PROHIBITED_CONTENT" => BLOCKED,
      "SPII" => BLOCKED,
      "BLOCKLIST" => BLOCKED,
      "OTHER" => ERROR,
      "IMAGE_OTHER" => ERROR,
      "NO_IMAGE" => ERROR,
      "MALFORMED_FUNCTION_CALL" => ERROR,
      "UNEXPECTED_TOOL_CALL" => ERROR,
      "TOO_MANY_TOOL_CALLS" => ERROR,
      "MISSING_THOUGHT_SIGNATURE" => ERROR,
      "MALFORMED_RESPONSE" => ERROR,
      # Every prompt block is a decline: an unclassified one would read as
      # a clean, empty finish.
      "PROMPT_BLOCKED_REASON_UNSPECIFIED" => REFUSED,
      "PROMPT_SAFETY" => REFUSED,
      "PROMPT_OTHER" => REFUSED,
      "PROMPT_IMAGE_SAFETY" => REFUSED,
      "PROMPT_JAILBREAK" => REFUSED,
      "PROMPT_PROHIBITED_CONTENT" => BLOCKED,
      "PROMPT_BLOCKLIST" => BLOCKED,
      "PROMPT_MODEL_ARMOR" => BLOCKED,
    }.freeze
    # finish_reason is the typed verdict on this wire; a refusal message ends
    # "stop" like any answer, so the Result types it "refusal".
    CHAT = {
      "length" => OUTPUT_BUDGET_EXHAUSTED,
      "content_filter" => REFUSED,
      "refusal" => REFUSED,
    }.freeze
    NONE = {}.freeze

    BY_ADAPTER_PROFILE = {
      "openai_responses" => RESPONSES,
      "codex_responses" => RESPONSES,
      "deepseek_responses" => RESPONSES,
      "xai_responses" => RESPONSES,
      "anthropic_messages" => MESSAGES,
      "gemini_generate_content" => GEMINI,
      "openrouter_chat" => CHAT,
      "openai_compatible_chat" => CHAT,
    }.freeze

    def self.for(adapter_profile:, detail:)
      BY_ADAPTER_PROFILE.fetch(adapter_profile.to_s, NONE).fetch(detail.to_s, nil)
    end

    # Whether a finish is a decline under its wire's own table — the one
    # question a lane asks before it attaches a Result#refusal, so the fact
    # and the quality can never disagree.
    def self.declined?(table, detail)
      DECLINED.include?(table.fetch(detail.to_s, nil))
    end
  end
end
