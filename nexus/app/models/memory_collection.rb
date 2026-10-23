class MemoryCollection < ApplicationRecord
  include PublicIdentified

  attr_readonly :account_id, :user_id, :workspace_id, :conversation_id, :speaker_id, :is_default, :public_id

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { owner.account }
  belongs_to :user, optional: true
  belongs_to :workspace, optional: true
  belongs_to :conversation, optional: true
  belongs_to :speaker, optional: true
  has_many :memory_documents, dependent: :restrict_with_exception

  scope :live, -> { where(deleted_at: nil) }
  scope :for_scope, ->(scope) {
    case scope
    when :user then joins(:user).where(users: { kind: :human })
    when :workspace then where.not(workspace_id: nil)
    when :conversation then where.not(conversation_id: nil)
    else all
    end
  }

  validates :name, length: { maximum: 128 }, allow_nil: true
  validates :description, length: { maximum: 1024 }, allow_nil: true
  validate :ownership
  validate :owner_available, on: :create

  def self.matching_name_or_id(query, default_name:, unnamed_name:)
    return all if query.blank?

    matches = where("memory_collections.name ILIKE :name OR memory_collections.public_id::text = :id",
      name: "%#{sanitize_sql_like(query)}%", id: query.downcase)
    matches = matches.or(where(name: [nil, ""], is_default: true)) if default_name.downcase.include?(query.downcase)
    matches = matches.or(where(name: [nil, ""], is_default: false)) if unnamed_name.downcase.include?(query.downcase)
    matches
  end

  # New owner births are already transactional. For an existing owner, the
  # accepting writer holds its parent lock before allocating a missing default.
  def self.default_for(owner, speaker: nil)
    owner.memory_collections.find_by(is_default: true, speaker: speaker) ||
      owner.memory_collections.create_or_find_by!(is_default: true, speaker: speaker)
  end

  def self.create_for(owner, **attributes)
    owner.with_lock("FOR NO KEY UPDATE") { owner.memory_collections.create!(**attributes) }
  end

  def owner = conversation || workspace || user

  def natural_scope
    if conversation_id then :conversation
    elsif workspace_id then :workspace
    elsif speaker_id then :speaker
    elsif user.agent? then :agent
    else :user
    end
  end

  def deleted? = deleted_at.present?
  def archived? = archived_at.present?

  # The owner orders writes with Fork. NO KEY UPDATE admits parent FK
  # checks while excluding other memory writers on that same owner.
  def with_mutation
    parent = owner || raise(ActiveRecord::RecordNotFound, "Memory owner was collected")
    parent.with_lock("FOR NO KEY UPDATE") do
      # State changes and document writes share the collection arbiter.
      with_lock { yield }
    end
  end

  def update_metadata(attributes, expected_lock_version:)
    mutate(expected_lock_version) do
      update(attributes) ? MemoryCollection::Result.accepted(self) : MemoryCollection::Result.invalid(self)
    end
  end

  def archive(expected_lock_version: nil)
    mutate(expected_lock_version) do
      update!(archived_at: Time.current) unless archived?
      MemoryCollection::Result.accepted(self)
    end
  end

  def restore(expected_lock_version: nil)
    mutate(expected_lock_version) do
      update!(archived_at: nil)
      MemoryCollection::Result.accepted(self)
    end
  end

  def tombstone(expected_lock_version: nil)
    result = mutate(expected_lock_version) do
      update!(deleted_at: Time.current, archived_at: nil, name: nil, description: nil)
      MemoryCollection::Result.accepted(self)
    end
    ActiveRecord.after_all_transactions_commit { MemoryCollections::PurgeJob.perform_later } if result.accepted?
    result
  end

  # The tombstone is retained until owner collection; only real document
  # references retain a shared version. Every call removes at most limit rows.
  def purge_documents(limit: MemoryDocument::MAX_DOCUMENTS_PER_COLLECTION)
    with_mutation do
      if deleted?
        rows = memory_documents.order(:id).limit(limit).pluck(:id, :memory_document_version_id)
        memory_documents.where(id: rows.map(&:first)).delete_all
        rows.map(&:last).uniq.each { |id| MemoryDocumentVersion.reclaim(id) }
        rows.length
      else
        0
      end
    end
  end

  private

    def mutate(expected_lock_version)
      with_mutation do
        next MemoryCollection::Result.refused(:not_found) if deleted?
        next MemoryCollection::Result.refused(:stale_object) if expected_lock_version && lock_version != expected_lock_version

        yield
      end
    end

    def ownership
      errors.add(:base, :exactly_one_anchor) unless [user_id, workspace_id, conversation_id].count(&:present?) == 1
      errors.add(:speaker, :invalid) if speaker && !(user&.agent? && speaker.account_id == account_id)
    end

    def owner_available
      unavailable = if conversation_id
        conversation.tombstoned?
      elsif workspace_id
        !workspace.live?
      elsif user_id
        !user.active?
      end
      errors.add(:base, :owner_unavailable) if unavailable
    end
end
