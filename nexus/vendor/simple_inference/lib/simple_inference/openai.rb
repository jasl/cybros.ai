module SimpleInference
  # Helpers for extracting common fields from OpenAI-compatible `chat/completions` payloads.
  #
  # These helpers accept either:
  # - A `SimpleInference::Response`, or
  # - A parsed `body` / `chunk` hash (typically from JSON.parse, with String keys)
  #
  # Providers are "OpenAI-compatible", but many differ in subtle ways:
  # - Some return `choices[0].text` instead of `choices[0].message.content`
  # - Some represent `content` as an array or structured hash
  #
  # This module normalizes those shapes so application code can stay small and predictable.
  module OpenAI
    module_function

    ChatResult = Data.define(:content, :usage, :finish_reason, :logprobs, :response)

    # Extract assistant content from a non-streaming chat completion.
    #
    # @param response_or_body [Hash] SimpleInference response hash or parsed body hash
    # @return [String, nil]
    def chat_completion_content(response_or_body)
      body = unwrap_body(response_or_body)
      choice = first_choice(body)
      return nil unless choice

      raw =
        choice.dig("message", "content") ||
          choice["text"]

      normalize_content(raw)
    end

    # Extract finish_reason from a non-streaming chat completion.
    #
    # @param response_or_body [Hash] SimpleInference response hash or parsed body hash
    # @return [String, nil]
    def chat_completion_finish_reason(response_or_body)
      body = unwrap_body(response_or_body)
      first_choice(body)&.[]("finish_reason")
    end

    # Extract usage from a chat completion response or a final streaming chunk.
    #
    # @param response_or_body [Hash] SimpleInference response hash, body hash, or chunk hash
    # @return [Hash, nil] usage hash
    def chat_completion_usage(response_or_body)
      unwrap_body(response_or_body)["usage"]
    end

    # Extract logprobs (if present) from a non-streaming chat completion.
    #
    # @param response_or_body [Hash] SimpleInference response hash or parsed body hash
    # @return [Array<Hash>, nil]
    def chat_completion_logprobs(response_or_body)
      body = unwrap_body(response_or_body)
      first_choice(body)&.dig("logprobs", "content")
    end

    # Extract delta content from a streaming `chat.completion.chunk`.
    #
    # @param chunk [Hash] parsed streaming event hash
    # @return [String, nil]
    def chat_completion_chunk_delta(chunk)
      normalize_content(unwrap_body(chunk).dig("choices", 0, "delta", "content"))
    end

    # Extract a refusal delta from a streaming `chat.completion.chunk`: the
    # model declining arrives as `delta.refusal`, never as content.
    #
    # @param chunk [Hash] parsed streaming event hash
    # @return [String, nil]
    def chat_completion_chunk_refusal_delta(chunk)
      normalize_content(unwrap_body(chunk).dig("choices", 0, "delta", "refusal"))
    end

    def chat_completion_chunk_reasoning_delta(chunk)
      delta = unwrap_body(chunk).dig("choices", 0, "delta")
      return nil if delta.nil?

      # `reasoning_content` is the DeepSeek/most-providers field; `reasoning` is OpenRouter's
      # unified field (e.g. open-weight models served via OpenRouter). Capture either.
      raw = delta["reasoning_content"] || delta["reasoning"]
      normalize_content(raw)
    end

    # Normalize `content` shapes into a simple String.
    #
    # Supports strings, arrays of parts, and part hashes.
    #
    # @param value [Object]
    # @return [String, nil]
    def normalize_content(value)
      case value
      when String
        value
      when Array
        value.map { |part| normalize_content(part) }.join
      when Hash
        value["text"] ||
          value["content"] ||
          value.to_s
      when nil
        nil
      else
        value.to_s
      end
    end

    # These helpers take either a Response or its parsed body — the one
    # declared union at this module's door; the result is always the body Hash.
    def unwrap_body(obj)
      case obj
      when SimpleInference::Response then obj.body || {}
      when nil then {}
      else obj
      end
    end

    def first_choice(body)
      body.dig("choices", 0)
    end
    private_class_method :first_choice
  end
end
