require "digest"

module Nexus
  # The database-independent identity of one structured content payload.
  # Canonical bytes are returned with their account-salted digest so every
  # writer measures and addresses the exact same representation.
  ContentAddress = Data.define(:canonical_payload, :digest, :byte_size) do
    class << self
      def for(account_id:, payload:)
        canonical_payload = CanonicalJson.encode(payload)

        new(
          canonical_payload: canonical_payload,
          digest: Digest::SHA256.hexdigest("#{account_id}\n#{canonical_payload}"),
          byte_size: canonical_payload.bytesize,
        )
      end
    end
  end
end
