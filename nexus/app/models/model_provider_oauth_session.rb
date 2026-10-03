# One OAuth authorization for a provider lane — a device start or a refresh. It owns the semantic layer; delivery facts
# live on the OAuthTask children. One nonterminal per lane, enforced by the policy-row lock, not an index.
class ModelProviderOAuthSession < ApplicationRecord
  KINDS = %w[device_start token_refresh].freeze
  STATES = %w[pending completed failed revoked expired].freeze
  # Domain bounds for one device authorization; the adapter only parses the
  # provider's wire spelling into these values.
  POLL_INTERVAL_SECONDS = (1..900).freeze
  AUTHORIZATION_WINDOW_SECONDS = 900

  REFRESH_TOKEN_FAILURE_OUTCOMES = %w[
    refresh_token_expired refresh_token_reused refresh_token_invalidated
  ].freeze
  PROVIDER_TERMINAL_OUTCOMES = (
    %w[
      device_code_not_enabled provider_error malformed_response
      oversized_response oversized_field incomplete_response
      unsupported_poll_interval unusable_expiry
    ] + REFRESH_TOKEN_FAILURE_OUTCOMES + %w[refresh_rejected]
  ).freeze

  # Progress is kind-specific: a refresh has no human in it, so it never
  # awaits a user and never exchanges a code.
  PROGRESS = {
    "device_start" => %w[accepted requesting_code awaiting_user polling exchanging_code].freeze,
    "token_refresh" => %w[accepted refreshing].freeze,
  }.freeze

  EXCHANGE_KINDS = {
    "device_start" => %w[user_code_request device_token_poll code_exchange].freeze,
    "token_refresh" => %w[token_refresh].freeze,
  }.freeze

  # The terminal detail behind a terminal state, for rendering and branching
  # only. The domain owns the stored vocabulary; response normalization maps
  # provider failures into this closed set.
  OUTCOMES = (
    PROVIDER_TERMINAL_OUTCOMES +
    %w[authorized authorization_deadline_exceeded operator_revoked superseded ambiguous_delivery]
  ).freeze

  belongs_to :account
  belongs_to :issuing_user, class_name: "User"
  has_many :oauth_tasks,
    class_name: "ModelProviderOAuthTask",
    foreign_key: :model_provider_oauth_session_id,
    inverse_of: :oauth_session,
    dependent: :restrict_with_error

  attr_readonly :account_id, :provider_id, :issuing_user_id, :public_id, :kind,
    :authorization_lineage_id

  encrypts :device_auth_id
  encrypts :user_code
  encrypts :authorization_code
  encrypts :code_challenge
  encrypts :code_verifier

  validates :provider_id, presence: true, length: { maximum: 64 }
  validates :kind, inclusion: { in: KINDS }
  enum :state, STATES.index_by(&:itself), default: :pending, validate: true, scopes: false
  validates :authorization_lineage_id, presence: true
  validates :semantic_exchange_ordinal,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: AUTHORIZATION_WINDOW_SECONDS }
  validates :poll_interval_seconds,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: POLL_INTERVAL_SECONDS.min,
      less_than_or_equal_to: POLL_INTERVAL_SECONDS.max,
    }, allow_nil: true
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  validate :authorization_window_matches_the_formula
  validate :ordinal_stays_within_the_interval_ceiling
  validate :progress_belongs_to_the_kind
  validate :semantic_exchange_belongs_to_the_kind
  validate :authorization_window_is_all_or_none
  validate :only_a_device_start_carries_a_window
  validate :grant_is_all_or_none
  validate :grant_belongs_to_a_pending_code_exchange
  validate :source_triple_is_all_or_none
  validate :a_refresh_names_its_source

  scope :nonterminal, -> { where(state: "pending") }

  # The caller holds the provider Policy lock, shared with acceptance/install.
  # Both disable and disconnect cancel pending authorization under that lock.
  def self.revoke_for_provider(account:, provider_id:, reason:, now: Time.current)
    nonterminal.where(account_id: account.id, provider_id: provider_id).lock.to_a.count do |session|
      session.terminalize(
        state: "revoked", outcome: "operator_revoked", sanitized_reason: reason, now: now
      )
    end
  end

  # On the model so a job cannot widen it. Zero-based ordinals under
  # `ceil(900 / interval)` admit upstream's `floor(900 / interval) + 1` polls;
  # the deadline is the real bound. nil for an interval the numericality check already rejected.
  def poll_ordinal_ceiling
    interval = poll_interval_seconds
    return nil unless POLL_INTERVAL_SECONDS.cover?(interval)

    (AUTHORIZATION_WINDOW_SECONDS + interval - 1) / interval
  end

  def device_start? = kind == "device_start"
  def token_refresh? = kind == "token_refresh"

  # First terminal writer wins, so a revoke racing an expiry cannot produce
  # two explanations. Returns the row, or nil when another writer got there first.
  def terminalize(state:, outcome:, sanitized_reason: nil, now: Time.current)
    won = self.class.where(id: id, state: "pending").update_all(
      state: state, outcome: outcome, sanitized_reason: sanitized_reason,
      next_action_at: nil,
      # Every terminal transition clears the live device facts and the whole
      # grant atomically: a stopped session must not leave a spendable code or
      # a renderable user code behind.
      device_auth_id: nil, user_code: nil, verification_uri: nil,
      authorization_code: nil, code_challenge: nil, code_verifier: nil,
      updated_at: now
    )
    return nil if won.zero?

    reload
  end

  private

    def progress_belongs_to_the_kind
      return if PROGRESS.fetch(kind, []).include?(progress)

      errors.add(:progress, :not_for_kind, kind: kind)
    end

    def semantic_exchange_belongs_to_the_kind
      return if semantic_exchange_kind.nil?
      return if EXCHANGE_KINDS.fetch(kind, []).include?(semantic_exchange_kind)

      errors.add(:semantic_exchange_kind, :unreachable_from_kind, kind: kind)
    end

    # Both are frozen by one successful user-code apply, so one without the
    # other is a torn write rather than a legal intermediate state.
    def authorization_window_is_all_or_none
      return if poll_started_at.present? == authorization_deadline_at.present?

      errors.add(:authorization_deadline_at, :torn_window)
    end

    # Derived, not chosen: a free column checked only for presence would let
    # a caller widen its own authorization window.
    def authorization_window_matches_the_formula
      return if poll_started_at.nil? || authorization_deadline_at.nil?
      return if authorization_deadline_at.to_i ==
        (poll_started_at + AUTHORIZATION_WINDOW_SECONDS).to_i

      errors.add(:authorization_deadline_at, :off_formula, seconds: AUTHORIZATION_WINDOW_SECONDS)
    end

    # The absolute 900 ceiling is the numeric bound; this is the real one. At a
    # 5-second interval the window holds 180 polls, so an ordinal of 200 is a
    # scheduler that lost track of its own deadline.
    def ordinal_stays_within_the_interval_ceiling
      ceiling = poll_ordinal_ceiling
      return if ceiling.nil?
      return if semantic_exchange_ordinal <= ceiling

      errors.add(:semantic_exchange_ordinal, :beyond_interval_ceiling,
        ceiling: ceiling, interval: poll_interval_seconds)
    end

    def only_a_device_start_carries_a_window
      return unless token_refresh?
      return if poll_started_at.nil? && authorization_deadline_at.nil? && poll_interval_seconds.nil?

      errors.add(:base, :refresh_has_no_window)
    end

    def grant_is_all_or_none
      present = [authorization_code, code_challenge, code_verifier].map(&:present?).uniq
      return if present.length <= 1

      errors.add(:base, :torn_grant)
    end

    # The grant is spendable exactly once, so it exists only where it can be
    # spent: a live device start that has reached the exchange.
    def grant_belongs_to_a_pending_code_exchange
      return if authorization_code.blank?
      return if device_start? && state == "pending" && progress == "exchanging_code"

      errors.add(:base, :grant_outside_code_exchange)
    end

    def source_triple_is_all_or_none
      present = [source_credential_public_id, source_authorization_lineage_id, source_generation]
        .map { |value| !value.nil? }.uniq
      return if present.length <= 1

      errors.add(:base, :torn_source_triple)
    end

    # A refresh rotates a specific credential. Without the triple it could
    # install over whatever happens to be current when it lands, which is the
    # exact ambiguity the fence exists to prevent.
    def a_refresh_names_its_source
      return unless token_refresh?
      return if source_credential_public_id.present?

      errors.add(:source_credential_public_id, :required_for_refresh)
    end
end
