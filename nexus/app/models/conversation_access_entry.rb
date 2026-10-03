# One named principal's level on one conversation: the row the access
# carrier keeps beside the conversation's default. The creator and the
# answerer never hold one — they are full by derivation
# (Conversation#access_level_for reads that clause first, so a stray row
# cannot demote them). No validation beyond the enum: every writer
# resolves its principals through the account's own users, the fork copies
# by `insert_all!` where validations never run, and the unique
# `[conversation_id, user_id]` index is the whole integrity contract.
class ConversationAccessEntry < ApplicationRecord
  attr_readonly :account_id, :conversation_id, :user_id

  belongs_to :account, default: -> { conversation&.account }
  belongs_to :conversation
  belongs_to :user

  # One list, one owner: the conversation's default words are the entry's.
  enum :level, Conversation.access_defaults, validate: true, scopes: false, prefix: :level
end
