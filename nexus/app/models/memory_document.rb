# The pointer row the model addresses as `user/notes.md`, `workspace/notes.md`
# or `conversation/plan.md`: an anchor (exactly one of the three rungs), a
# name, and the version whose bytes are the content. A fork copies the
# conversation rung's rows and nothing else; MemoryDocumentVersion says why that is safe.
#
# A SKILL IS A ROW UNDER `skills/` WITH A DESCRIPTION:
# the prefix is the kind — no `kind` column, no third model — and
# `Nexus::Skills` owns the grammar. The cap is SHARED with plain memory:
# sixty-four documents of every kind per rung.
class MemoryDocument < ApplicationRecord
  SCOPES = %w[conversation workspace user].freeze
  NAME_MAX_LENGTH = 128
  # Lowercase because a path is typed back from a model's own earlier output,
  # and a case-insensitive near-collision is a confusion the cap does not bound.
  NAME_FORMAT = %r{\A[a-z0-9][a-z0-9_.\-/]*\z}
  MAX_DOCUMENTS_PER_ANCHOR = 64
  # The agentskills specification's bound on a skill's description; a plain
  # document carries none (the writer refuses one outside `skills/`).
  DESCRIPTION_MAX_LENGTH = Nexus::Skills::DESCRIPTION_MAX_LENGTH
  # THE ONE PREDICATE FOR THE PREFIX IN SQL, written once and read by the
  # two scopes below: the assembly block's exclusion, the catalog's plucks
  # and any listing all say `skills/` through here.
  SKILLS_PATTERN = "#{Nexus::Skills::PREFIX}%".freeze

  attr_readonly :account_id, :conversation_id, :workspace_id, :user_id, :name, :public_id

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :conversation, optional: true
  belongs_to :workspace, optional: true
  belongs_to :user, optional: true
  belongs_to :memory_document_version

  scope :for_conversation, ->(id) { where(conversation_id: id) }
  scope :for_workspace, ->(id) { where(workspace_id: id, conversation_id: nil) }
  scope :for_user, ->(id) { where(user_id: id) }
  scope :skills, -> { where("memory_documents.name LIKE ?", SKILLS_PATTERN) }
  scope :not_skills, -> { where("memory_documents.name NOT LIKE ?", SKILLS_PATTERN) }

  validates :name, presence: true
  validates :name,
    length: { maximum: NAME_MAX_LENGTH },
    format: { with: NAME_FORMAT },
    allow_nil: true
  validates :description, length: { maximum: DESCRIPTION_MAX_LENGTH }, allow_nil: true
  validate :exactly_one_anchor

  class << self
    # THE ONE DERIVATION of the model-facing path: the scope IS the first
    # segment, so a path read out of a listing can be handed straight back
    # to any other verb. A class method because the listing and the block
    # pluck ids rather than load rows (content must never detoast to choose).
    def path_for(name, conversation_id:, workspace_id:, user_id:)
      "#{scope_for(conversation_id: conversation_id, workspace_id: workspace_id,
        user_id: user_id)}/#{name}"
    end

    def scope_for(conversation_id:, workspace_id:, user_id:)
      return "conversation" if conversation_id
      return "workspace" if workspace_id
      return "user" if user_id

      nil
    end
  end

  def path
    self.class.path_for(name, conversation_id: conversation_id, workspace_id: workspace_id,
      user_id: user_id)
  end

  # The prefix ALONE: the writer guarantees the description, so a second
  # condition here would be a second definition of the kind.
  def skill? = Nexus::Skills.reserved?(name)

  def content = memory_document_version.content
  def bytesize = memory_document_version.bytesize

  private

    # The one arbiter — there is no CHECK; the three partial unique indexes
    # are the structural backstop.
    def exactly_one_anchor
      return if [conversation_id, workspace_id, user_id].count(&:present?) == 1

      errors.add(:base, :exactly_one_anchor)
    end
end
