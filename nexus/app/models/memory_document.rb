class MemoryDocument < ApplicationRecord
  # Every document points to one collection and one immutable content version.
  # Owner and optional Speaker subject belong to the collection.
  NAME_MAX_LENGTH = 128
  # Lowercase because a path is typed back from a model's own earlier output,
  # and a case-insensitive near-collision is a confusion the cap does not bound.
  NAME_FORMAT = %r{\A[a-z0-9][a-z0-9_.\-/]*\z}
  MAX_DOCUMENTS_PER_COLLECTION = 64
  # The agentskills specification's bound on a skill's description; a plain
  # document carries none (the writer refuses one outside `skills/`).
  DESCRIPTION_MAX_LENGTH = Nexus::Skills::DESCRIPTION_MAX_LENGTH
  # THE ONE PREDICATE FOR THE PREFIX IN SQL, written once and read by the
  # two scopes below: the assembly block's exclusion, the catalog's plucks
  # and any listing all say `skills/` through here.
  SKILLS_PATTERN = "#{Nexus::Skills::PREFIX}%".freeze

  attr_readonly :account_id, :memory_collection_id, :name, :public_id

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :memory_collection
  belongs_to :account, default: -> { memory_collection.account }
  belongs_to :memory_document_version

  scope :skills, -> { where("memory_documents.name LIKE ?", SKILLS_PATTERN) }
  scope :not_skills, -> { where("memory_documents.name NOT LIKE ?", SKILLS_PATTERN) }

  validates :name, presence: true
  validates :name,
    length: { maximum: NAME_MAX_LENGTH },
    format: { with: NAME_FORMAT },
    allow_nil: true
  validates :description, length: { maximum: DESCRIPTION_MAX_LENGTH }, allow_nil: true

  def path = "#{memory_collection.natural_scope}/#{name}"

  # The prefix ALONE: the writer guarantees the description, so a second
  # condition here would be a second definition of the kind.
  def skill? = Nexus::Skills.reserved?(name)

  def content = memory_document_version.content
  def bytesize = memory_document_version.bytesize
end
