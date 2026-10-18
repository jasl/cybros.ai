# An accepted command and its first observation belong to the executing task.
# Its key survives explicit retries; only the task owns execution and scheduling.
class TaskOperation < ApplicationRecord
  OPERATION_KEY_MAX_LENGTH = 128

  attr_readonly :account_id, :task_id, :operation_key, :kind,
    :request_digest, :request, :response, :position

  belongs_to :account, default: -> { task&.account }
  belongs_to :task, inverse_of: :task_operations
  has_many :content_bodies, dependent: :destroy, inverse_of: :task_operation
  has_one :observation_body, -> { where(role: "observation") }, class_name: "ContentBody",
    inverse_of: :task_operation

  validates :operation_key, presence: true, length: { maximum: OPERATION_KEY_MAX_LENGTH },
    uniqueness: { scope: :task_id }
  validates :kind, presence: true
  validates :request_digest, presence: true, length: { is: 64 }
  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :observed_position, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :request, :response, bounded_json: { bound: :snapshot_bound, shape: Hash }
  validates :observation, bounded_json: { bound: :snapshot_bound, shape: Hash }, allow_nil: true
  validate :observation_moves_once
  validate :observation_has_a_position

  def readable_by?(user) = task.readable_by?(user)

  private

    # A retried child may replace its output. The observation envelope and its
    # separately sealed body keep exactly the value this execution first read.
    def observation_moves_once
      return if observed_position_was.nil?

      errors.add(:observed_position, :readonly) if observed_position_changed?
      errors.add(:observation, :readonly) if observation_changed?
    end

    def observation_has_a_position
      if observed_position.nil? != observation.nil?
        errors.add(:observation, :partial_fact)
      end
    end
end
