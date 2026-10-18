class Identity < ApplicationRecord
  EMAIL_MAX_LENGTH = 255
  PASSWORD_MIN_LENGTH = 8
  PASSWORD_MAX_BYTES = BCrypt::Engine::MAX_SECRET_BYTESIZE

  attr_readonly :account_id

  belongs_to :account
  has_one :user
  has_many :sessions, dependent: :destroy

  has_secure_password

  class << self
    # BCrypt cannot represent NUL and silently ignores bytes after its
    # 72-byte input boundary. Keep that representation check in one place for
    # every application-owned hashing and verification entry point.
    def bcrypt_compatible_password?(password)
      candidate = password.to_s
      !candidate.include?("\0") && candidate.bytesize <= PASSWORD_MAX_BYTES
    end
  end

  # Keep invalid input available to model validation without handing it to the
  # generated writer, which would invoke BCrypt before validations run.
  def password=(unencrypted_password)
    if self.class.bcrypt_compatible_password?(unencrypted_password)
      super
    else
      @password = unencrypted_password
    end
  end

  # Rails' authenticate_by calls authenticate_password, while application
  # workflows also use its authenticate alias. Both must share the same guard.
  def authenticate_password(unencrypted_password)
    return false unless self.class.bcrypt_compatible_password?(unencrypted_password)

    super
  end
  alias_method :authenticate, :authenticate_password

  # Bind the token to the password and email state without embedding the raw
  # address in the signed (but readable) payload. The timestamp also prevents
  # an email A → B → A round trip from reviving a token issued for the first A.
  generates_token_for :password_reset, expires_in: 15.minutes do
    [password_salt&.last(10), Digest::SHA256.hexdigest(email), updated_at&.iso8601(6)]
  end

  normalizes :email, with: ->(value) { value.strip.downcase.presence }

  validates :email,
    presence: true,
    length: { maximum: EMAIL_MAX_LENGTH },
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: true
  validates :password, length: { minimum: PASSWORD_MIN_LENGTH }, allow_nil: true
  validate :password_is_bcrypt_compatible
  # Rails skips the confirmation check when the field is absent, so presence
  # is demanded here; the credential operations run their own pair checks.
  validates :password_confirmation, presence: true, if: -> { password.present? }

  # One accepted state change: the password change invalidates outstanding
  # reset tokens and the generation advance fences every earlier Session.
  # Returns :reset, :superseded or :invalid_input.
  def reset_password(token:, password:, password_confirmation:)
    digest = prepare_password_digest(password, password_confirmation)
    return :invalid_input unless digest

    # Re-resolving the token inside the lock is the final acceptance decision.
    with_lock do
      if self.class.find_by_password_reset_token(token) != self || !password_resettable?
        :superseded
      else
        update!(
          password_digest: digest,
          password_change_required: false,
          credential_recovery_generation: credential_recovery_generation + 1
        )
        :reset
      end
    end
  end

  # An address held by an open Invitation is rejected rather than stranding it.
  # Outstanding reset tokens die with the old address.
  def change_email(new_email, current_password:)
    unless authenticate(current_password)
      errors.add(:current_password, :invalid)
      return false
    end

    if Invitation.exists?(email: self.class.normalize_value_for(:email, new_email))
      errors.add(:email, :held_by_invitation)
      return false
    end

    verified_digest = password_digest

    # Email changes invalidate reset links, and a completed reset invalidates
    # this password proof. Serialize those writes without holding a lock for BCrypt.
    with_lock do
      if password_digest != verified_digest
        errors.add(:current_password, :invalid)
        false
      else
        update(email: new_email)
      end
    end
  end

  # Current-password proof, then mutation, generation advance and exactly one
  # replacement Session as one outcome; every earlier Session is fenced.
  # Returns the replacement Session, or nil with errors on the record.
  def change_password(current_password:, password:, password_confirmation:, presented_session:, user_agent: nil, ip_address: nil)
    digest = prepare_password_digest(password, password_confirmation)
    return unless digest

    unless authenticate(current_password)
      errors.add(:current_password, :invalid)
      return
    end

    verified_digest = password_digest

    # Short locks, no BCrypt inside; Identity then User. A concurrent
    # revoke/reap wins by making the guarded DELETE affect zero rows.
    with_lock do
      member = if presented_session
        User.lock.find_by(id: presented_session.user_id, identity_id: id, status: :active)
      end

      if password_digest != verified_digest || local_recovery_pending? || member.nil?
        errors.add(:base, :not_changeable)
        nil
      elsif !Session.consume_for_password_change(session: presented_session, identity: self, user: member)
        errors.add(:base, :session_no_longer_valid)
        raise ActiveRecord::Rollback
      else
        update!(
          password_digest: digest,
          password_change_required: false,
          credential_recovery_generation: credential_recovery_generation + 1
        )
        sessions.create!(
          account: account,
          user: member,
          user_agent: user_agent&.first(255),
          ip_address: ip_address
        )
      end
    end
  end

  # Local-recovery consume: password change, consumption and fence clear as one state
  # change; the generation stays at n, so every pre-fence credential stays dead.
  # Returns:recovered,:superseded or:invalid_input.
  def consume_local_recovery(authorization:, password:, password_confirmation:)
    digest = prepare_password_digest(password, password_confirmation)
    return :invalid_input unless digest

    # The lock is the final acceptance point; the reload lets a repeated
    # consume observe the first winner's consumed_at.
    with_lock do
      if !authorization.reload.consumable? || authorization.identity_id != id || !user&.human? || !user.active?
        :superseded
      else
        authorization.update!(consumed_at: Time.current)
        update!(
          password_digest: digest,
          password_change_required: false,
          local_recovery_pending_at: nil
        )
        :recovered
      end
    end
  end

  # One eligibility rule for scheduling reset mail and for consuming a reset
  # token: an active human member whose local-recovery fence is clear.
  def password_resettable?
    user.present? && user.human? && user.active? && !local_recovery_pending?
  end

  def local_recovery_pending?
    local_recovery_pending_at.present?
  end

  private

    def password_is_bcrypt_compatible
      # Rails' own secure-password validator supplies :password_too_long for
      # the byte limit; this application validation owns the native NUL gap.
      if password.to_s.include?("\0")
        errors.add(:password, :invalid)
      end
    end

    # BCrypt runs outside any lock and the declared validations judge the
    # pair (Rails ignores a blank password=, guarded here).
    def prepare_password_digest(password, password_confirmation)
      if password.blank?
        errors.add(:password, :blank)
        return
      end

      self.password = password
      self.password_confirmation = password_confirmation
      return unless valid?

      password_digest.tap { reload }
    end
end
