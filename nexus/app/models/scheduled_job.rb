# A durable instruction and clock. Each dispatch creates an ordinary child
# conversation; its execution and final reply remain owned by the existing turn.
class ScheduledJob < ApplicationRecord
  include InputIntent

  STATUSES = %w[active paused canceled completed].freeze
  FUTURE_BOUND = ConversationInput::FUTURE_BOUND

  attr_readonly :account_id, :conversation_id, :creating_user_id, :public_id,
    :source_agent_loop_public_id, :source_task_key
  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { conversation&.account }
  belongs_to :conversation
  belongs_to :creating_user, class_name: "User"
  belongs_to :answering_user, class_name: "User", default: -> { conversation&.answering_user }
  belongs_to :last_execution_conversation, class_name: "Conversation", optional: true
  has_many :execution_conversations, class_name: "Conversation"

  enum :status, STATUSES.index_by(&:itself), default: :active, validate: true, scopes: false
  validates :name, length: { maximum: 255 }, allow_nil: true
  validates :prompt, :provider_id, :model_ref, presence: true
  validates :last_error_code, length: { maximum: 64 }, allow_nil: true
  validates :source_task_key, length: { maximum: 255 }, allow_nil: true
  validates :rule, bounded_json: { bound: :envelope_bound, shape: Hash }
  validate :valid_rule
  validate :prompt_fits_input
  validate :owners_share_the_account
  validate :source_names_the_creating_task, on: :create
  normalizes :name, with: ->(value) { value.to_s.strip.presence }
  before_validation :normalize_rule, if: :rule_changed?

  scope :due, ->(at) { where(status: "active", next_run_at: ..at) }

  def schedule = Rule.parse(rule)

  # Called at create or an explicit rule edit/resume. A past one-time date
  # is refused; recurrence always resumes at a future nominal occurrence.
  def reset_clock(now)
    candidate = schedule.next_after(now)
    if candidate.nil? || candidate > now + FUTURE_BOUND
      errors.add(:rule, :invalid)
      return false
    end

    self.next_run_at = candidate
    true
  end

  private

    def normalize_rule
      self.rule = schedule.to_h
    end

    def valid_rule
      parsed = schedule
      unless parsed.valid?
        parsed.errors.each { |error| errors.add(:rule, error.message) }
      end
    end

    def prompt_fits_input
      size = Nexus::CanonicalJson.bytesize({ "text" => prompt.to_s })
      unless Nexus::SizeBounds.bytes_within?(:snapshot_bound, size)
        errors.add(:prompt, Nexus::SizeBounds::REJECTION)
      end
    end

    def owners_share_the_account
      errors.add(:creating_user, :invalid) if creating_user && creating_user.account_id != account_id
      errors.add(:answering_user, :invalid) if answering_user && answering_user.account_id != account_id
    end

    def source_names_the_creating_task
      return if source_agent_loop_public_id.nil? && source_task_key.nil?

      source = conversation&.hosted_agent_loops&.find_by(public_id: source_agent_loop_public_id)
      errors.add(:source_agent_loop_public_id, :invalid) unless source &&
        source.agent_loop_nodes.exists?(node_key: source_task_key)
    end
end
