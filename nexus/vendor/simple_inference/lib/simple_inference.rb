require_relative "simple_inference/version"
require_relative "simple_inference/internal/keys"
require_relative "simple_inference/internal/envelope"
require_relative "simple_inference/config"
require_relative "simple_inference/errors"
require_relative "simple_inference/http_adapter"
require_relative "simple_inference/response"
require_relative "simple_inference/openai"
require_relative "simple_inference/measure"
require_relative "simple_inference/media_type"
require_relative "simple_inference/media_input"
require_relative "simple_inference/multipart_body"
require_relative "simple_inference/execution_profile"
require_relative "simple_inference/compiled_request"
require_relative "simple_inference/planning/request_validator"
require_relative "simple_inference/finish_quality"
require_relative "simple_inference/responses/result"
require_relative "simple_inference/responses/stream"
require_relative "simple_inference/images/result"
require_relative "simple_inference/audio/speech_result"
require_relative "simple_inference/audio/transcription_result"
require_relative "simple_inference/embeddings/result"
require_relative "simple_inference/resources/responses"
require_relative "simple_inference/resources/images"
require_relative "simple_inference/resources/audio"
require_relative "simple_inference/resources/embeddings"
require_relative "simple_inference/protocols/base"
require_relative "simple_inference/protocols/openai_compatible"
require_relative "simple_inference/protocols/openai_compatible_responses"
require_relative "simple_inference/protocols/mistral_chat"
require_relative "simple_inference/protocols/openai_responses"
require_relative "simple_inference/protocols/openai_images"
require_relative "simple_inference/protocols/openai_audio_speech"
require_relative "simple_inference/protocols/openai_audio_transcriptions"
require_relative "simple_inference/protocols/openai_embeddings"
require_relative "simple_inference/protocols/codex_responses"
require_relative "simple_inference/protocols/deepseek_responses"
require_relative "simple_inference/protocols/openrouter_responses"
require_relative "simple_inference/protocols/gemini_generate_content"
require_relative "simple_inference/protocols/gemini_embeddings"
require_relative "simple_inference/protocols/anthropic_messages"
require_relative "simple_inference/protocols/bedrock_converse"
require_relative "simple_inference/protocols/pi_messages"
require_relative "simple_inference/protocols/xai_responses"
require_relative "simple_inference/api_format"
require_relative "simple_inference/client"

module SimpleInference
  class << self
    # Convenience constructor.
    #
    # Example:
    #   client = SimpleInference.new(execution_profile: profile, base_url: "...", api_key: "...")
    def new(**options)
      Client.new(**options)
    end
  end
end
