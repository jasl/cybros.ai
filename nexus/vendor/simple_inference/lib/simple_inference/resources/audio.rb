module SimpleInference
  module Resources
    class Audio
      def initialize(client:)
        @client = client
      end

      def speech
        @speech ||= Speech.new(client: @client)
      end

      def transcriptions
        @transcriptions ||= Transcriptions.new(client: @client)
      end

      class Speech
        def initialize(client:)
          @client = client
        end

        def create(model:, input:, voice:, **options)
          raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?
          raise SimpleInference::ValidationError, "input is required" if input.nil? || input.to_s.strip.empty?
          raise SimpleInference::ValidationError, "voice is required" if voice.nil? || voice.to_s.strip.empty?

          options = Planning::RequestValidator.validate_speech_request(
            profile: @client.execution_profile, model: model, options: options
          )
          @client.execute(compile_from_validated(model: model, input: input, voice: voice, **options))
        end

        def compile_from_validated(model:, input:, voice:, **options)
          protocol.compile_create(model: model, input: input, voice: voice, **options)
        end

        private

        def protocol
          ApiFormat.protocol_for(profile: @client.execution_profile, config: @client.config)
        end
      end

      class Transcriptions
        def initialize(client:)
          @client = client
        end

        def create(model:, file:, **options)
          raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?
          raise SimpleInference::ValidationError, "file is required" if file.nil?

          options = Planning::RequestValidator.validate_transcription_request(
            profile: @client.execution_profile, model: model, options: options
          )
          @client.execute(protocol.compile_create(model: model, file: file, **options))
        end

        def compile_from_validated(model:, media:, filename: nil, **options)
          protocol.compile_from_media(
            model: model, media: media, filename: filename, **options
          )
        end

        private

        def protocol
          ApiFormat.protocol_for(profile: @client.execution_profile, config: @client.config)
        end
      end
    end
  end
end
