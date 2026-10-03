# The bounded namespaced JSON current-value store over three hosts: data
# the model never reads as text — no assembly block, no tool, no prompt
# reads a row here, and that test is what separates a store from memory.
# The three hosts are User, Workspace and Conversation, and the User
# scope is the ACTING principal's own row: an agent's store is the
# agent's, not its steward's. A row is a mutable current value under
# optimistic locking, never a fork-shared pointer — the recorded
# difference from a memory document.
class StoreEntry < ApplicationRecord
  NAMESPACE_MAX_LENGTH = 80
  NAMESPACE_FORMAT = /\A[a-z0-9][a-z0-9_.-]*\z/
  KEY_MAX_LENGTH = 160
  MAX_ENTRIES_PER_HOST = 64

  attr_readonly :account_id, :workspace_id, :conversation_id, :user_id, :public_id,
    :namespace, :key

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { host&.account }
  belongs_to :workspace, optional: true
  belongs_to :conversation, optional: true
  belongs_to :user, optional: true

  scope :for_workspace, ->(id) { where(workspace_id: id) }
  scope :for_conversation, ->(id) { where(conversation_id: id) }
  scope :for_user, ->(id) { where(user_id: id) }

  validates :namespace, presence: true
  validates :namespace,
    length: { maximum: NAMESPACE_MAX_LENGTH },
    format: { with: NAMESPACE_FORMAT },
    allow_nil: true
  validates :key, presence: true
  validates :key, length: { maximum: KEY_MAX_LENGTH }, allow_nil: true
  validate :exactly_one_anchor
  # Friendly logical-identity validation; the partial unique index per host
  # is the race winner. A nil scope value compares as IS NULL, so this one
  # validation covers the three hosts. Postgres text rejects NUL, so skip
  # uniqueness for such input to avoid an adapter error.
  validates :key,
    uniqueness: { scope: %i[user_id workspace_id conversation_id namespace] },
    unless: -> { key.nil? || key.include?("\0") }
  # Values are kernel-opaque JSON, JSON null included.
  # An application's recoverable current state is a snapshot, not a command
  # envelope. It stays one atomic JSON value under the existing snapshot bound.
  validates :value, bounded_json: { bound: :snapshot_bound }

  # The one anchor: the row every write's authority and the create's cap
  # count hang on — in ladder order users and workspaces rank above
  # conversations (`lock_order_guard_test.rb`).
  def host = user || workspace || conversation

  private

    # The one arbiter — there is no CHECK; the three partial unique indexes
    # are the structural backstop.
    def exactly_one_anchor
      return if [workspace_id, conversation_id, user_id].count(&:present?) == 1

      errors.add(:base, :exactly_one_anchor)
    end
end
