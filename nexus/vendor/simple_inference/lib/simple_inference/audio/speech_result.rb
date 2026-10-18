module SimpleInference
  module Audio
    # The provider's audio bytes and declared response type. Active Storage is
    # the owner of durable binary output; this value does not copy, fingerprint,
    # or re-identify bytes that the protocol already received.
    SpeechResult = Data.define(:audio, :mime_type, :provider_response, :provider_format) do
      def initialize(audio:, mime_type:, provider_response:, provider_format:)
        super(audio: audio.to_s, mime_type: mime_type.to_s, provider_response:, provider_format:)
      end
    end
  end
end
