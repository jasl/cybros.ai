module Nexus
  # The one digested-secret wire discipline: "PREFIX-lookup.secret", lookup = urlsafe_base64(18),
  # secret = urlsafe_base64(32), stored as HMAC-SHA256 keyed per family. Parsing is strict before
  # any database traffic; raw secrets exist only at mint.
  class DigestedSecret
    LOOKUP_BYTES = 18
    SECRET_BYTES = 32
    DIGEST_KEY_BYTES = 32
    LOOKUP_LENGTH = 24
    SECRET_LENGTH = 43

    Parts = Data.define(:lookup_id, :secret, :raw, :digest)
    Wire = Data.define(:lookup_id, :secret)

    def initialize(prefix:, digest_salt:)
      @prefix = prefix
      @digest_salt = digest_salt
      @wire_length = prefix.bytesize + 1 + LOOKUP_LENGTH + 1 + SECRET_LENGTH
      @wire_format = /\A#{Regexp.escape(prefix)}-(?<lookup_id>[A-Za-z0-9_-]{#{LOOKUP_LENGTH}})\.(?<secret>[A-Za-z0-9_-]{#{SECRET_LENGTH}})\z/
    end

    attr_reader :prefix

    def mint_parts
      lookup_id = SecureRandom.urlsafe_base64(LOOKUP_BYTES)
      secret = SecureRandom.urlsafe_base64(SECRET_BYTES)
      Parts.new(
        lookup_id: lookup_id,
        secret: secret,
        raw: "#{prefix}-#{lookup_id}.#{secret}",
        digest: digest(lookup_id: lookup_id, secret: secret),
      )
    end

    def parse(raw)
      raw = raw.to_s
      return unless raw.bytesize == @wire_length

      match = @wire_format.match(raw)
      return if match.nil?

      Wire.new(lookup_id: match[:lookup_id], secret: match[:secret])
    end

    def digest(lookup_id:, secret:)
      OpenSSL::HMAC.hexdigest("SHA256", digest_key, "#{lookup_id}.#{secret}")
    end

    def digest_matches?(stored_digest, lookup_id:, secret:)
      ActiveSupport::SecurityUtils.secure_compare(digest(lookup_id: lookup_id, secret: secret), stored_digest)
    end

    private

      # Rails' CachingKeyGenerator memoizes the PBKDF2 derivation per salt, so
      # per-request digest work is one HMAC, and rotating secret_key_base
      # retires every family's digests together.
      def digest_key
        Rails.application.key_generator.generate_key(@digest_salt, DIGEST_KEY_BYTES)
      end
  end
end
