module SimpleInference
  module Audio
    # The transformed transcription result. text is NULLABLE and preserves
    # the wire's omitted-vs-valid-empty distinction (C2-1, probe-confirmed
    # 2026-08-09): a body without a "text" member stays nil (missing
    # transcript), while a wire "" stays "" (valid empty transcript).
    TranscriptionResult = Data.define(:text, :usage, :provider_response, :provider_format) do
      def initialize(text:, usage:, provider_response:, provider_format:)
        super(text: text.nil? ? nil : text.to_s.freeze, usage:, provider_response:, provider_format:)
      end
    end
  end
end
