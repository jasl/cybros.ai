class Invitation < ApplicationRecord
  include PublicIdentified
  EMAIL_MAX_LENGTH = 255
  VALIDITY_PERIOD = 7.days
  RESEND_INTERVAL = 60.seconds

  # The closed acceptance outcome controllers map to HTML: `member` is present
  # only for :accepted; `errors` only for :rejected (validation failures on
  # the submitted display name/password).
  Acceptance = Data.define(:outcome, :member, :errors)

  attr_readonly :account_id, :inviter_id, :public_id, :email, :role

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :inviter, class_name: "User"

  enum :role, %w[member admin].index_by(&:itself), default: :member, validate: true, scopes: false

  normalizes :email, with: ->(value) { value.strip.downcase.presence }

  before_validation :assign_delivery_request_defaults, on: :create

  validates :email,
    presence: true,
    length: { maximum: EMAIL_MAX_LENGTH },
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: true
  validate :email_not_already_registered, on: :create

  scope :unexpired, -> { where.not(expires_at: ..Time.current) }
  scope :order_by_recency, -> { order(created_at: :desc, id: :desc) }

  class << self
    # Signed over the public id with no verifier-level expiry, so resend
    # renewal applies to every mailed link and deletion invalidates them all.
    def find_by_acceptance_token(token)
      public_id = acceptance_verifier.verified(token)
      unexpired.find_by(public_id: public_id) if public_id
    end

    def acceptance_verifier
      Rails.application.message_verifier("invitation_acceptance")
    end
  end

  # Expiry is a derived invalidity predicate, never a stored status; an
  # expired row stays the unique invitation for its address until accepted,
  # deleted, or renewed by resend.
  def expired?
    expires_at <= Time.current
  end

  def acceptance_token
    self.class.acceptance_verifier.generate(public_id)
  end

  def resend_available_in
    if last_delivery_requested_at.nil?
      0
    else
      (last_delivery_requested_at + RESEND_INTERVAL - Time.current).clamp(0..)
    end
  end

  # A mail-less creation recorded no delivery request; the row is link-only
  # until its first accepted resend.
  def delivery_requested?
    last_delivery_requested_at.present?
  end

  # One accepted delivery request per row per 60 seconds. The guarded UPDATE
  # is the winner rule for concurrent resend clicks: losing the compare
  # changes nothing and schedules no mail.
  def resend
    if Identity.exists?(email: email)
      :member_already_exists
    elsif !ApplicationMailer.delivery_configured?
      :mail_delivery_unavailable
    else
      now = Time.current
      current = self.class.where(id: id)
      renewed = current.where(last_delivery_requested_at: nil)
        .or(current.where(last_delivery_requested_at: ..(now - RESEND_INTERVAL)))
        .update_all(last_delivery_requested_at: now, expires_at: now + VALIDITY_PERIOD, updated_at: now)

      if renewed == 1
        deliver_later
        :resent
      else
        self.last_delivery_requested_at = self.class.where(id: id).pick(:last_delivery_requested_at)
        :resend_too_soon
      end
    end
  end

  # Mail is scheduled with the JSON-native public id, never a record or a raw
  # capability; a job that can no longer load the row sends nothing.
  def deliver_later
    InvitationMailer.acceptance(public_id).deliver_later
  end

  # Recheck validity and email availability, create Identity/User with the
  # invited email and role, destroy the Invitation. Possession of the link
  # does not prove control of the mailbox.
  def accept(display_name:, password:, password_confirmation:)
    if Identity.exists?(email: email)
      Acceptance.new(outcome: :member_already_exists, member: nil, errors: nil)
    else
      # Prepare BCrypt before opening the acceptance transaction. This new
      # credential has no existing authority that could become stale; its
      # validation, insertion, membership, and final consumption stay atomic.
      identity = account.identities.build(
        email: email,
        password: password,
        password_confirmation: password_confirmation
      )

      transaction do
        identity.save!
        member = account.users.create!(
          kind: :human, role: role, identity: identity, display_name: display_name
        )
        # Deleting the row is the acceptance winner rule: losing to a
        # concurrent revoke (or another acceptance) rolls the member creation
        # back, so a revoked invitation can never still mint a member.
        consumed = self.class.where(id: id).where.not(expires_at: ..Time.current).delete_all
        raise ActiveRecord::RecordNotFound, "Invitation is no longer valid" unless consumed == 1

        Acceptance.new(outcome: :accepted, member: member, errors: nil)
      end
    end
  rescue ActiveRecord::RecordInvalid => error
    Acceptance.new(outcome: :rejected, member: nil, errors: error.record.errors)
  end

  private

    # Expiry anchors on creation regardless of mail capability; the delivery
    # timestamp is stamped only when creation also schedules mail — a
    # mail-less creation is link-only delivery.
    def assign_delivery_request_defaults
      self.last_delivery_requested_at ||= Time.current if ApplicationMailer.delivery_configured?
      self.expires_at ||= VALIDITY_PERIOD.from_now
    end

    def email_not_already_registered
      if Identity.exists?(email: email)
        errors.add(:email, :member_already_exists)
      end
    end
end
