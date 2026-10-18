# One immutable body of memory text, shared by pointer: a fork copies only
# pointer rows, which is safe because a version is written once. Not
# content-addressed — sharing is by pointer, so no adopt-vs-reap apparatus.
class MemoryDocumentVersion < ApplicationRecord
  CONTENT_BOUND = :memory_document_bound

  attr_readonly :account_id, :content, :created_at

  belongs_to :account
  # RESTRICT at the database: a version with a pointer cannot be deleted,
  # which is what makes the reclaim below safe to lose.
  has_many :memory_documents, dependent: :restrict_with_exception

  validates :content, exclusion: { in: [nil] }
  validate :content_must_be_bounded

  # `bytesize` is a stored generated column (`octet_length(content)`), the
  # database's own count. Rails reads a generated column back on UPDATE but
  # not on INSERT, so a created row takes its count from the row once — the
  # memory write's settle line and presenter read it straight after.
  after_create :read_bytesize

  # Called by the writer once it has repointed; a lost race is an outcome —
  # the RESTRICT FK refuses and the row survives for the teardown sweep.
  def self.reclaim(id)
    return false if id.nil?

    where(id: id).where.missing(:memory_documents).delete_all.positive?
  rescue ActiveRecord::InvalidForeignKey
    false
  end

  private

    def read_bytesize
      self[:bytesize] = self.class.where(id: id).pick(:bytesize)
      clear_attribute_changes([:bytesize])
    end

    def content_must_be_bounded
      return if content.nil?

      unless Nexus::SizeBounds.bytes_within?(CONTENT_BOUND, content.to_s.bytesize)
        errors.add(:content, Nexus::SizeBounds::REJECTION)
      end
      # Postgres text cannot store U+0000, and an INSERT that discovers it
      # aborts the enclosing transaction rather than refusing politely.
      errors.add(:content, :unsupported_text) if content.include?("\u0000")
    end
end
