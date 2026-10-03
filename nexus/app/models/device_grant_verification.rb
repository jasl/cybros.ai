# One successful browser-context verification of one DeviceAuthorization.
# The row is a bounded, parent-owned capability fact: it has no lifecycle of
# its own and disappears with the short-lived authorization.
class DeviceGrantVerification < ApplicationRecord
  BROWSER_CONTEXT_LENGTH = 43
  BROWSER_CONTEXT_FORMAT = /\A[A-Za-z0-9_-]{#{BROWSER_CONTEXT_LENGTH}}\z/
  BROWSER_CONTEXT_DIGEST_FORMAT = /\A[0-9a-f]{64}\z/
  KEY_BYTES = 32
  BROWSER_CONTEXT_DIGEST_SALT =
    "cybros/device_grant_verification/browser_context".freeze
  SESSION_CONTEXT_DERIVATION_SALT =
    "cybros/device_grant_verification/browser_session_context".freeze

  attr_readonly :account_id, :device_authorization_id, :browser_context_digest

  belongs_to :account, default: -> { device_authorization.account }
  belongs_to :device_authorization

  validates :browser_context_digest,
    presence: true,
    format: { with: BROWSER_CONTEXT_DIGEST_FORMAT },
    uniqueness: { scope: :device_authorization_id }
  validate :account_matches_authorization

  class << self
    # Derived from the browser Session so concurrent first responses converge
    # instead of racing two Set-Cookie values; a dedicated HMAC key keeps it
    # unlinkable to the Session's public id.
    def browser_context_for(session:)
      unless session.browser? && session.public_id.present?
        raise ArgumentError, "a resolved browser Session is required"
      end

      Base64.urlsafe_encode64(
        OpenSSL::HMAC.digest("SHA256", session_context_derivation_key, session.public_id),
        padding: false
      )
    end

    def digest_browser_context(raw)
      raw = raw.to_s
      return unless raw.match?(BROWSER_CONTEXT_FORMAT)

      OpenSSL::HMAC.hexdigest("SHA256", digest_key, raw)
    end

    # The parent row owns both the five-context budget and child insertion.
    # Locking it serializes duplicate/different-context verifications so two
    # tabs cannot double-charge one context or mint a sixth capability.
    def record(authorization:, browser_context_digest:)
      authorization.with_lock do
        existing = find_by(
          device_authorization: authorization,
          browser_context_digest: browser_context_digest
        )
        if existing
          existing
        elsif authorization.charge_exposure
          authorization.device_grant_verifications.create!(
            browser_context_digest: browser_context_digest
          )
        end
      end
    end

    private

      def digest_key
        Rails.application.key_generator.generate_key(
          BROWSER_CONTEXT_DIGEST_SALT,
          KEY_BYTES
        )
      end

      def session_context_derivation_key
        Rails.application.key_generator.generate_key(
          SESSION_CONTEXT_DERIVATION_SALT,
          KEY_BYTES
        )
      end
  end

  private

    def account_matches_authorization
      if device_authorization && device_authorization.account_id != account_id
        errors.add(:account, :authorization_mismatch)
      end
    end
end
