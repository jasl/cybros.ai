# Deployment-local recovery: one show-once secret per recovery generation.
# Minting advances the generation and sets the pending fence; only the
# current-generation secret clears it.
class MemberRecoveryAuthorization < ApplicationRecord
  DIGESTED = Nexus::DigestedSecret.new(
    prefix: "rc-cybros-v1",
    digest_salt: "cybros/member_recovery/secret_digest"
  )
  # The public reset form routes recovery submissions by this wire prefix.
  WIRE_PREFIX = "#{DIGESTED.prefix}-".freeze
  SECRET_LIFETIME = 15.minutes
  EVIDENCE_RETENTION = 30.days

  include Convergence

  attr_readonly :account_id, :identity_id, :user_id, :generation, :lookup_id, :secret_digest

  belongs_to :account
  belongs_to :identity
  belongs_to :user

  scope :current, -> { where(consumed_at: nil, superseded_at: nil) }

  class << self
    # Strict wire parse before any database traffic, then a constant-time
    # digest comparison against the row the embedded lookup id names.
    def find_by_secret(raw)
      wire = DIGESTED.parse(raw)

      if wire
        authorization = find_by(lookup_id: wire.lookup_id)
        if authorization && DIGESTED.digest_matches?(authorization.secret_digest, lookup_id: wire.lookup_id, secret: wire.secret)
          authorization
        end
      end
    end
  end

  # The consumable predicate: still bound to an active human, current,
  # unexpired, and minted for the Identity's present recovery generation — a
  # re-mint supersedes older secrets by advancing that generation.
  def consumable?
    user.human? &&
      user.active? &&
      user.identity_id == identity_id &&
      consumed_at.nil? &&
      superseded_at.nil? &&
      expires_at.future? &&
      generation == identity.credential_recovery_generation
  end
end
