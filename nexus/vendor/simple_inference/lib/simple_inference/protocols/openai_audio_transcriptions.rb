require_relative "base"
require_relative "../media_input"
require_relative "../media_type"

module SimpleInference
  module Protocols
    class OpenAIAudioTranscriptions < Base
      # This parser handles JSON responses only.
      RESPONSE_FORMATS = %w[json].freeze

      # The standard OpenAI transcription options this protocol forwards as
      # multipart form fields (stream is deliberately absent — this protocol's
      # contract is one buffered JSON response); provider-specific form fields
      # ride extra_body.
      def self.request_option_keys
        %i[
          chunking_strategy include language prompt response_format
          temperature timestamp_granularities
        ].freeze
      end

      def initialize(transcriptions_path: nil, **connection)
        super(**connection)
        @transcriptions_path = normalize_transcriptions_path(
          transcriptions_path || "#{config.api_prefix}/audio/transcriptions",
        )
      end

      # Public callers supply raw bytes in `file[:body]`. This boundary detects
      # their MIME type and rejects a conflicting declared content type.
      def create(model:, file:, **options)
        compile_create(model: model, file: file, **options).execute(config)
      end

      def compile_create(model:, file:, **options)
        declared, extra_body = split_request_options(options)
        validate_response_format(declared[:response_format]) if declared.key?(:response_format)
        media = ingest_file(file)
        compile_from_media_parts(
          model: model, media: media, filename: file[:filename],
          declared: declared, extra_body: extra_body
        )
      end

      # Internal compile path for a caller that already crossed its media
      # boundary. The Active Storage owner supplies normalized bytes/MIME, so
      # this layer lowers them without another sniff or copy.
      def compile_from_media(model:, media:, filename: nil, **options)
        declared, extra_body = split_request_options(options)
        validate_response_format(declared[:response_format]) if declared.key?(:response_format)
        compile_from_media_parts(
          model: model, media: media, filename: filename,
          declared: declared, extra_body: extra_body
        )
      end

      private

      def compile_from_media_parts(model:, media:, filename:, declared:, extra_body:)
        parts = multipart_parts(
          model: model, file: multipart_file_part(media, filename: filename),
          declared: declared, extra_body: extra_body
        )

        compile_multipart_request(path: @transcriptions_path, parts: parts) do |connection_config, compiled|
          transcription_result_from_response(compiled_response(compiled, config: connection_config))
        end
      end

      def transcription_result_from_response(response)
        body = response.body || {}
        SimpleInference::Audio::TranscriptionResult.new(
          text: body["text"],
          usage: body["usage"],
          provider_response: response,
          provider_format: "audio.transcriptions",
        )
      end

      def validate_response_format(value)
        return if RESPONSE_FORMATS.include?(value.to_s)

        raise SimpleInference::ValidationError,
              "response_format #{value.inspect} is unsupported; transcription accepts json only"
      end

      # The caller's upload enters here once: a symbol-keyed file-part Hash.
      def ingest_file(file)
        file = Hash.try_convert(file)
        if file.nil?
          raise SimpleInference::ValidationError,
                "file must be a symbol-keyed Hash carrying raw audio bytes via :body"
        end
        if file.key?(:path) || file.key?("path")
          raise SimpleInference::ValidationError,
                "multipart file parts carry raw bytes via :body — filesystem paths are not accepted"
        end

        media = ingest_media(file)
        return media if MediaType.audio?(media.media_type)

        raise SimpleInference::ValidationError,
              "detected media type #{media.media_type} is not audio; the transcription route accepts audio bytes only"
      end

      def ingest_media(file)
        body = file[:body]
        if body.nil?
          raise SimpleInference::ValidationError,
                "file must carry raw audio bytes via the symbol key :body " \
                "(got keys #{file.keys.inspect})"
        end

        MediaInput.from_bytes(body, declared_media_type: declared_media_type(file))
      end

      def declared_media_type(file)
        value = file[:content_type]
        return nil if value.nil?

        value.to_s
      end

      # The multipart request, one form part per wire field — declared options
      # map 1:1 onto same-named non-file fields.
      def multipart_parts(model:, file:, declared:, extra_body:)
        parts = [
          { name: "model", value: model },
          { name: "file", value: file },
          *declared.map { |key, value| { name: key.to_s, value: value } },
        ]

        finalize_multipart_parts(parts, extra_body)
      end

      def normalize_transcriptions_path(value)
        path = value.to_s.strip
        path = "#{config.api_prefix}/audio/transcriptions" if path.empty?
        path = "/#{path}" unless path.start_with?("/")

        prefix = config.api_prefix.to_s
        return path if prefix.empty? || path.start_with?("#{prefix}/") || path == prefix
        return path unless config.base_url_included_api_prefix?

        "#{prefix}#{path}"
      end
    end
  end
end
