# One replayable narration item on the one hosted plane (a Conversation, a
# standalone AgentRun, or — for `handle_changed` alone — a member). Unlike the InferenceRequest plane, items age out while the
# host lives — Turn + ContentBody are the record, items are replay evidence.
class ConversationEventItem < ApplicationRecord
  include AgeReapable

  RETENTION = 30.days
  # One closed vocabulary for every host: not every type appears on every
  # host; `handle_changed` appears on a member only.
  ITEM_TYPES = %w[
    input_accepted
    input_edited
    input_deleted
    input_materialized
    input_blocked
    turn_created
    turn_status
    turn_variant
    task_status
    round_result
    usage
    attention_required
    context_trimmed
    context_compacted
    reasoning_replay_downgraded
    fork_created
    visibility
    soft_delete
    turn_deleted
    default_runner_changed
    task_readdressed
    task_deadline_extended
    access_changed
    handle_changed
    conversation_ended
  ].freeze

  # `payload` deliberately NOT readonly, mirroring InferenceRequestEventItem: the
  # writer composes items before append and the mirror's shape is the law.
  attr_readonly :account_id, :conversation_event_id, :host_type, :host_id,
    :public_id, :sequence, :item_type, :occurred_at

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :conversation_event
  belongs_to :host, polymorphic: true

  scope :after_sequence, ->(sequence) { where(sequence: (sequence + 1)..) }

  validates :item_type, inclusion: { in: ITEM_TYPES }
  validates :sequence, numericality: { only_integer: true, greater_than: 0 }
  validates :occurred_at, presence: true

  validates :payload, bounded_json: { bound: :envelope_bound }
end
