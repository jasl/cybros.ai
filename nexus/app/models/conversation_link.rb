class ConversationLink < ApplicationRecord
  include PublicIdentified
  include Authority

  CLOSE_REASONS = %w[explicit principal_unavailable steward_changed endpoint_access_lost
                     workspace_access_lost endpoint_deleted taken_over].freeze

  attr_readonly :public_id, :account_id, :workspace_id,
    :first_conversation_id, :first_agent_id, :second_conversation_id, :second_agent_id
  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { workspace.account }
  belongs_to :workspace
  belongs_to :first_conversation, class_name: "Conversation"
  belongs_to :second_conversation, class_name: "Conversation"
  belongs_to :first_agent, class_name: "User"
  belongs_to :second_agent, class_name: "User"
  has_many :inputs

  scope :active, -> { where(closed_at: nil) }
  scope :for_conversation, ->(conversation) {
    where(first_conversation_id: conversation.id).or(where(second_conversation_id: conversation.id))
  }

  validates :close_reason, inclusion: { in: CLOSE_REASONS }, allow_nil: true
  validates :close_reason, presence: true, if: :closed?
  validates :close_reason, absence: true, unless: :closed?
  validate :endpoints_share_workspace

  def closed? = closed_at.present?
  def state = closed? ? "closed" : "active"

  def peer(conversation:, agent:)
    if first_conversation_id == conversation.id && first_agent_id == agent.id
      [second_conversation, second_agent]
    elsif second_conversation_id == conversation.id && second_agent_id == agent.id
      [first_conversation, first_agent]
    end
  end

  # The guarded UPDATE is the authority cut. It conflicts with a consumer's
  # shared lock and never acquires either Conversation or Run afterward.
  def close(reason: "explicit", acting_user: nil)
    transaction do
      now = Time.current
      changed = self.class.where(id: id, closed_at: nil)
        .update_all(closed_at: now, close_reason: reason, updated_at: now)
      if changed.positive?
        self.closed_at, self.close_reason, self.updated_at = now, reason, now
        narrate(acting_user: acting_user)
        [first_conversation, second_conversation].each do |conversation|
          Conversations::Inputs::DrainJob.perform_later(conversation.id)
        end
      end
    end
    self
  end

  def narrate(acting_user:)
    payload = { "link_public_id" => public_id, "state" => state, "close_reason" => close_reason }
    if acting_user
      payload.merge!("by" => acting_user.public_id, "kind" => acting_user.agent? ? "agent" : "human")
    end
    [first_conversation, second_conversation].sort_by(&:id).each do |conversation|
      Event::Append.call(host: conversation, items: [{ type: "conversation_link_changed", payload: payload }])
    end
  end

  private

    def endpoints_share_workspace
      if first_conversation && second_conversation &&
          (first_conversation_id >= second_conversation_id ||
            first_conversation.workspace_id != workspace_id || second_conversation.workspace_id != workspace_id ||
            first_conversation.side? || second_conversation.side?)
        errors.add(:base, :invalid)
      end
      if first_agent && second_agent &&
          (first_agent.account_id != account_id || second_agent.account_id != account_id ||
            !first_agent.agent? || !second_agent.agent?)
        errors.add(:base, :invalid)
      end
    end
end
