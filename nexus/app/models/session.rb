class Session < ApplicationRecord
  include PublicIdentified
  # Absolute lifetime from issuance; activity never extends it.
  LIFETIME = 30.days
  REAP_BATCH_SIZE = 1_000
  DIGESTED = Nexus::DigestedSecret.new(
    prefix: "sk-cybros-session-v1",
    digest_salt: "cybros/session/api_token_digest"
  )

  attr_readonly :account_id, :identity_id, :user_id, :public_id, :kind, :lookup_id, :secret_digest

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :identity
  belongs_to :account, default: -> { identity.account }
  belongs_to :user, default: -> { identity.user }

  enum :kind, %w[browser api].index_by(&:itself), default: :browser, validate: true, scopes: false

  validates :lookup_id, :secret_digest, presence: true, if: :api?
  validates :lookup_id, :secret_digest, absence: true, unless: :api?

  before_create :assign_expiry
  before_create :freeze_authority_snapshots

  scope :order_by_recency, -> { order(created_at: :desc, id: :desc) }
  # Rows fenced by an advanced generation: immediately unusable for
  # authentication, retained only until the reap collects them.
  scope :fenced, -> {
    joins(:identity, :user).where(
      "sessions.identity_recovery_generation <> identities.credential_recovery_generation
        OR sessions.user_authority_generation <> users.authority_generation"
    )
  }

  # The personal active-sessions list: unexpired rows whose frozen snapshots
  # still match the identity's current generations — fenced sessions are
  # dead and never render as active.
  scope :listable_for, ->(identity) {
    where(identity: identity).where.not(expires_at: ..Time.current)
      .where(
        identity_recovery_generation: identity.credential_recovery_generation,
        user_authority_generation: identity.user.authority_generation
      )
      .order_by_recency
  }

  # Storage only: authentication already rejects expired and fenced rows. The expiry phase
  # self-advances on `(expires_at, id)`; the fenced phase takes a primary-key window first
  # because its cross-table comparison has no index.
  def self.reap(now: Time.current, batch_size: REAP_BATCH_SIZE, fenced_after_id: 0)
    expired_ids = where(expires_at: ..now)
      .order(:expires_at, :id).limit(batch_size).pluck(:id)
    expired_count = where(id: expired_ids).delete_all

    window = where(id: (fenced_after_id + 1)..)
      .order(:id).limit(batch_size - expired_ids.length).pluck(:id)
    fenced_count = fenced.where(id: window).delete_all

    Rails.logger.info(
      "event=sessions_reaped expired=#{expired_count} fenced=#{fenced_count}"
    )
    Sweeps::Pass.new(
      counts: { expired: expired_count, fenced: fenced_count, scanned: expired_ids.length + window.length },
      cursor: window.empty? ? fenced_after_id : window.last,
      more: expired_ids.length == batch_size ||
        window.length == batch_size - expired_ids.length
    )
  end

  # The one read-only resume rule shared by web requests and Action Cable:
  # resolve the cookie's public id and apply the validity predicate. Cookie
  # resume never crosses into the api kind.
  def self.find_usable(public_id)
    if public_id.present?
      session = includes(:user, :identity).find_by(public_id: public_id, kind: :browser)
      session if session&.usable?
    end
  end

  # Bearer authentication for the platform family: strict parse, lookup
  # fetch, the shared validity predicate, then constant-time comparison.
  def self.authenticate_api_token(raw)
    wire = DIGESTED.parse(raw)

    if wire
      session = includes(:user, :identity).find_by(lookup_id: wire.lookup_id, kind: :api)
      if session&.usable? && DIGESTED.digest_matches?(session.secret_digest, lookup_id: wire.lookup_id, secret: wire.secret)
        session
      end
    end
  end

  # Final authority check for an authenticated password change. The counted
  # DELETE is both validation and consumption: a revoked, expired, or fenced
  # Session changes no row and cannot authorize mutation.
  def self.consume_for_password_change(session:, identity:, user:)
    where(
      id: session.id,
      identity_recovery_generation: identity.credential_recovery_generation,
      user_authority_generation: user.authority_generation
    ).where.not(expires_at: ..Time.current).delete_all == 1
  end

  # The read-only validity predicate authentication uses: unexpired, an active
  # frozen User, generation snapshots equal to the current generations, and no
  # pending local-recovery fence.
  def usable?
    !expired? &&
      user.active? &&
      user_authority_generation == user.authority_generation &&
      identity_recovery_generation == identity.credential_recovery_generation &&
      !identity.local_recovery_pending?
  end

  def expired?
    expires_at <= Time.current
  end

  # Coarse, display-only label derived from the recorded user agent.
  def device_description
    return "API session" if api?

    case user_agent
    when /Mobile|Android|iPhone/ then "Mobile browser"
    when /Firefox/ then "Firefox"
    when /Edg\//i then "Edge"
    when /Chrome/ then "Chrome"
    when /Safari/ then "Safari"
    else "Web session"
    end
  end

  private

    def assign_expiry
      self.expires_at ||= LIFETIME.from_now
    end

    # A Session freezes the exact Identity/User authority it was issued under;
    # later generation advancements fence it without enumerating sessions.
    def freeze_authority_snapshots
      self.user_authority_generation ||= user.authority_generation
      self.identity_recovery_generation ||= identity.credential_recovery_generation
    end
end
