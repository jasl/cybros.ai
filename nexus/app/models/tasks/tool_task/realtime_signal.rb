class Tasks::ToolTask::RealtimeSignal
  include StoreModel::Model

  SDP_BYTES = 65_536
  CONNECTION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  FINGERPRINT = /\Aa=fingerprint:sha-256 ((?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})\z/

  attribute :connection_id, :string
  attribute :claim_digest, :string
  attribute :executor_credential_public_id, :string
  attribute :member_credential_public_id, :string
  attribute :offer_sdp, :string
  attribute :answer_sdp, :string

  validates :connection_id, format: { with: CONNECTION_ID }
  validates :claim_digest, :executor_credential_public_id, :offer_sdp, presence: true

  # Full gathered descriptions only. The authenticated description carries
  # its DTLS identity; consumers pass these exact bytes to their WebRTC stack.
  def self.description(value)
    text = value.to_s
    lines = text.split(/\r?\n/)
    fingerprints = lines.grep(/\Aa=fingerprint:/)
    unless text.bytesize <= SDP_BYTES && text.valid_encoding? && !text.include?("\0") &&
        lines.first == "v=0" && fingerprints.any? &&
        fingerprints.all? { |line| FINGERPRINT.match?(line) } &&
        fingerprints.map(&:downcase).uniq.one?
      raise ArgumentError, "invalid realtime SDP"
    end

    text
  end
end
