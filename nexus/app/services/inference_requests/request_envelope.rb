module InferenceRequests
  # The command a create's digest is taken over. An absent subject is an
  # explicit null because omission and null are different bytes; built before
  # selection so replay needs none of the first call's work.
  class RequestEnvelope
    Result = Data.define(:envelope, :request_digest, :refusal) do
      def self.accepted(envelope, request_digest)
        new(envelope: envelope, request_digest: request_digest, refusal: nil)
      end

      def self.refused(refusal)
        new(envelope: nil, request_digest: nil, refusal: refusal)
      end

      def accepted? = refusal.nil?
    end

    # Normalized through BillingSubject's own authority; absent, null and
    # blank still emit the explicit null so older digests keep their meaning.
    # A key too long to store is refused here, named for the bound, not at the INSERT.
    BILLING_SUBJECT_TOO_LONG = :billing_subject_too_long
    # An exponent-form number is the caller's data, and the digest is taken
    # before the grammar sees it, so this boundary answers rather than a 500.
    UNSUPPORTED_NUMBER = :unsupported_number
    # Wire JSON can spell a string PostgreSQL cannot store. The grammar asks
    # only whether a string is present, so without this the value would reach
    # the INSERT and abort the create with a database error.
    UNSUPPORTED_TEXT = :unsupported_text

    class << self
      def build(workload:, model_selection:, configuration:, input:, upload_public_ids:,
                billing_subject: nil)
        subject_key = BillingSubject.normalize_key(billing_subject)
        unless BillingSubject.key_within_bounds?(subject_key)
          return Result.refused(BILLING_SUBJECT_TOO_LONG)
        end

        envelope = {
          "model_selection" => json_value(model_selection),
          "configuration" => json_value(configuration),
          "input" => json_value(input),
          "upload_public_ids" => upload_public_ids,
          "billing_subject" => subject_key,
        }
        digest = InferenceRequestCreateReceipt.digest_for(workload: workload, envelope: envelope)
        Result.accepted(envelope, digest)
      rescue Nexus::CanonicalJson::UnsupportedNumber
        Result.refused(UNSUPPORTED_NUMBER)
      rescue Nexus::CanonicalJson::UnsupportedText
        Result.refused(UNSUPPORTED_TEXT)
      end

      private

        # The coerced command projected into canonical JSON, not a copy: a
        # member coercion dropped is not part of the command, and a shape
        # left alone is digested as it came.
        def json_value(value)
          case value
          when Hash then value.to_h { |key, element| [key.to_s, json_value(element)] }
          when Array then value.map { |element| json_value(element) }
          when Symbol then value.to_s
          when Nexus::TextInputMessage, Nexus::TextInputPart, Nexus::UploadInputPart,
               Nexus::OutputFormat
            json_value(value.to_h)
          else value
          end
        end
    end
  end
end
