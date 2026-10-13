# The one member access-token family: a human self-issues a personal token, an
# application receives OAuth credentials. The mint-frozen credential_plane
# is the credential-authority axis; the application scope does not subdivide it.
class AccessToken < ApplicationRecord
  include PublicIdentified
  include GuardedStamp
  DIGESTED = Nexus::DigestedSecret.new(
    prefix: "sk-cybros-api-v1",
    digest_salt: "cybros/access_token/token_digest"
  )
  NAME_MAX_LENGTH = 160
  NOTE_MAX_LENGTH = 2000
  LAST_USED_REFRESH_RATE = 1.hour
  # The single OAuth-minted access-token lifetime: device consume and
  # refresh rotation both mint at this TTL, and the wire expires_in must not
  # drift from it.
  OAUTH_TTL = 14.days

  include Convergence

  attr_readonly :account_id, :user_id, :public_id, :source,
    :lookup_id, :secret_digest, :expires_at,
    :user_authority_generation, :identity_recovery_generation,
    :task_executor_id, :credential_epoch, :refresh_token_family_id,
    :credential_plane

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  # A member credential belongs to its member; a runner's transport
  # credential has no owning member — the address is the whole subject.
  belongs_to :user, optional: true
  belongs_to :account, default: -> { user&.account || task_executor&.account }
  belongs_to :task_executor, optional: true
  belongs_to :refresh_token_family, optional: true

  enum :source, %w[personal oauth_device oauth_authorization oauth_refresh].index_by(&:itself),
    default: :personal, validate: true, scopes: false
  # The authorization plane this credential resolves to, fixed at mint:
  # member, executor transport, or a Human's platform token. No
  # stored secret ever satisfies two.
  enum :credential_plane, %w[member executor_transport platform].index_by(&:itself),
    default: :member, validate: true, scopes: false, suffix: :plane

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :note, length: { maximum: NOTE_MAX_LENGTH }, allow_nil: true
  validates :lookup_id, :secret_digest, presence: true
  validate :source_matches_user_kind
  validate :executor_binding_is_coherent
  validates :user, presence: true, if: :member_plane?
  validate :plane_binding_is_exclusive
  validate :refresh_family_is_coherent

  REAP_RETENTION = 30.days

  scope :order_by_recency, -> { order(created_at: :desc, id: :desc) }

  class << self
    # Strict parse -> lookup fetch -> liveness -> constant-time compare (the
    # oracle finder shape).
    def authenticate_token(raw)
      token = find_by_secret(raw)
      token.refresh_last_used_at if token&.usable?
    end

    # Executor-plane authentication does not inherit the acting Agent User's
    # lifecycle: a bound address keeps reconciling already-directed work while
    # User operability blocks member/data APIs and new admission.
    def authenticate_executor_token(raw)
      token = find_by_secret(raw)
      return nil unless token&.executor_usable?

      # The one door every executor-plane action enters, so the contact stamp
      # lives here; the two sampled writes stay independent — a contact sample
      # never moves the credential's own cutoff.
      token.task_executor&.refresh_last_seen_at(
        expected_epoch: token.credential_epoch
      )
      token.refresh_last_used_at
    end

    # Platform-plane authentication: the mint-frozen plane selects the
    # family; the caller still rechecks the live admin role, so the plane
    # alone never outlives a demotion.
    def authenticate_platform_token(raw)
      token = find_by_secret(raw)
      token.refresh_last_used_at if token&.platform_usable?
    end

    # Resolves a token by its digest without the liveness predicate: used for
    # revocation, where a dead-but-recognized token is still acted on
    # (RFC 7009) and never reveals its state.
    def find_by_secret(raw)
      wire = DIGESTED.parse(raw)
      return nil unless wire

      token = includes(:refresh_token_family, user: :identity)
        .find_by(lookup_id: wire.lookup_id)
      token if token && DIGESTED.digest_matches?(token.secret_digest, lookup_id: wire.lookup_id, secret: wire.secret)
    end
  end

  # Mirrors Session#usable?: generation comparisons, not enumerated
  # revocation, are the authority boundary; agent-owned tokens add the live
  # steward check, bound tokens the exact executor epoch.
  def usable?
    member_plane? &&
      revoked_at.nil? &&
      !expired? &&
      user.active? &&
      user_authority_generation == user.authority_generation &&
      (!user.human? ||
        (identity_recovery_generation == user.identity.credential_recovery_generation &&
          !user.identity.local_recovery_pending?)) &&
      user.steward_live? &&
      family_authority_live?
  end

  # A bound credential authorizes only its executor transport address under
  # the exact epoch; this is not member/data API authentication.
  def executor_usable?
    executor_transport_plane? &&
      revoked_at.nil? &&
      !expired? &&
      task_executor_id.present? &&
      task_executor.transport_authorized_at?(credential_epoch) &&
      family_authority_live?
  end

  # A platform token is a Human credential under the same
  # generation/recovery fences as usable?; the live admin-role recheck is the
  # serving controller's, keeping this predicate mechanical.
  def platform_usable?
    platform_plane? &&
      revoked_at.nil? &&
      !expired? &&
      user.active? &&
      user_authority_generation == user.authority_generation &&
      identity_recovery_generation == user.identity.credential_recovery_generation &&
      !user.identity.local_recovery_pending? &&
      !user.identity.password_change_required? &&
      family_authority_live?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def revoked?
    revoked_at.present?
  end

  # Guarded single-statement revocation: the loser of a concurrent double
  # revoke changes nothing and both converge on the same terminal state.
  def revoke = stamp_if(self.class.where(revoked_at: nil), :revoked_at, at: Time.current)

  # Coarse observability, never an authentication input: the persisted cutoff
  # lets one contender refresh per hour without a row lock.
  def refresh_last_used_at
    stamped_at = Time.current
    cutoff = stamped_at - LAST_USED_REFRESH_RATE
    return self if last_used_at.present? && last_used_at > cutoff

    refreshable = self.class.where(last_used_at: nil).or(self.class.where(last_used_at: ..cutoff))
    stamp_if(refreshable, :last_used_at, at: stamped_at)
  end

  private

    def source_matches_user_kind
      errors.add(:source, :personal_requires_human) if personal? && user&.agent?
    end

    # One bearer, one plane: a member credential never carries a delivery
    # address, a transport credential always does, a platform token carries
    # no executor address of its own.
    def plane_binding_is_exclusive
      if platform_plane?
        errors.add(:credential_plane, :platform_requires_human) unless user&.human?
      end

      if task_executor_id.present? && !executor_transport_plane?
        errors.add(:task_executor, :present)
      elsif executor_transport_plane? && task_executor_id.blank?
        errors.add(:task_executor, :blank)
      end
    end

    # Executor reference and epoch are both present or both NULL. The pair is
    # duplicated on the family on purpose: `executor_usable?` reads it off the
    # row in hand on every request.
    def executor_binding_is_coherent
      if task_executor_id.present? ^ credential_epoch.present?
        errors.add(:task_executor, :incomplete_binding)
      elsif task_executor
        if task_executor.agent_id != user_id || task_executor.account_id != account_id
          errors.add(:task_executor, :foreign_executor)
        end
      end
    end

    def refresh_family_is_coherent
      oauth_source = !personal?
      if oauth_source && !refresh_token_family
        errors.add(:refresh_token_family, :blank)
      elsif !oauth_source && refresh_token_family
        errors.add(:refresh_token_family, :unexpected)
      elsif refresh_token_family
        family = refresh_token_family
        # One connection is one lineage issuing both planes, so the executor
        # binding is checked per plane, not across the bundle.
        binding_coherent =
          if executor_transport_plane?
            family.task_executor_id == task_executor_id &&
              family.credential_epoch == credential_epoch
          else
            task_executor_id.nil? && credential_epoch.nil?
          end

        unless family.account_id == account_id &&
            family.user_id == user_id &&
            family.access_token_name == name &&
            binding_coherent &&
            family.user_authority_generation == user_authority_generation &&
            family.identity_recovery_generation == identity_recovery_generation
          errors.add(:refresh_token_family, :incoherent)
        end
      end
    end

    def family_authority_live?
      personal? ||
        (refresh_token_family && !refresh_token_family.revoked? &&
          (!platform_plane? || refresh_token_family.application_binding_live?(user)))
    end
end
