# Who spoke — a member's own voice, a bare speaker (an Speaker whose
# whole identity is its own row: no controlling User, no bridge, not the
# kernel), an ingress bridge, the system — never
# an auth principal: authority is the frozen User beside it on every Input and
# Turn. A member session authors speech only through an Speaker its User controls.
#
# An ingress Speaker is registered by its controlling Agent. The bridge's
# natural key resolves the same voice without transferring its authority.
# `persona` remains reserved for a future persona consumer.
class Speaker < ApplicationRecord
  KINDS = %w[member persona ingress system].freeze

  attr_readonly :account_id, :public_id, :kind, :channel_key, :external_id,
    :user_id

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :user, optional: true

  # The friendly destroy story: speech survives its speaker only through the
  # turns that recorded it, so an Speaker with history refuses to die loudly
  # rather than raising a raw FK violation.
  has_many :conversation_turns, foreign_key: :speaker_id,
    dependent: :restrict_with_error, inverse_of: :speaker
  has_many :conversation_inputs, foreign_key: :speaker_id,
    dependent: :restrict_with_error, inverse_of: :speaker

  validates :kind, inclusion: { in: KINDS }
  validates :channel_key, presence: true, length: { maximum: 64 }
  validates :external_id, presence: true, length: { maximum: 128 }
  validates :display_name, presence: true, length: { maximum: 100 }
  # A member Speaker without a controlling User would be speech nobody answers for.
  validates :user, presence: true, if: -> { kind == "member" }
  validate :user_must_share_the_account
  validate :ingress_must_have_an_agent
  validates :metadata, bounded_json: { bound: :speaker_metadata_bound, shape: Hash }

  def self.register_ingress(user:, channel_key:, external_id:, display_name:)
    create_or_find_by(account: user.account, channel_key: channel_key, external_id: external_id) do |actor|
      actor.kind = "ingress"
      actor.user = user
      actor.display_name = display_name
    end
  end

  def ingress_controlled_by?(principal)
    kind == "ingress" && account_id == principal.account_id && user_id == principal.id && principal.agent_member?
  end

  private

    def ingress_must_have_an_agent
      return unless kind == "ingress"

      errors.add(:user, :invalid) unless user&.agent_member?
      errors.add(:channel_key, :invalid) if %w[member system].include?(channel_key)
    end

    # Speaker selection is an authorization boundary: a controlling User from
    # another account would let a foreign principal speak here.
    def user_must_share_the_account
      return if user.nil? || user.account_id == account_id

      errors.add(:user, :invalid)
    end
end
