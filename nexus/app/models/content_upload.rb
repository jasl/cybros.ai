# One uploaded blob available for later binding.
class ContentUpload < ApplicationRecord
  CONTENT_TYPE_ALIASES = { "audio/x-wav" => "audio/wav" }.freeze
  ORPHAN_GRACE = 1.day
  REAP_BATCH_SIZE = 500

  # THE CREATOR IS ANCHOR-SHAPED: exactly one of a member (`creating_user`
  # — the member and session doors) or an executor (`creating_executor` —
  # a CAPTURE the executor publishes on its own plane). Both are readonly,
  # so the executor creator is set at `create!` alone (`attr_readonly`
  # RAISES on a later write; `creator.content_upload_anchor` is that one
  # write). The two FKs are the structural backstop; the arbiter is the
  # validation below, never a CHECK.
  attr_readonly :account_id, :creating_user_id, :creating_executor_id, :public_id

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :creating_user, class_name: "User", optional: true
  belongs_to :creating_executor, class_name: "TaskExecutor", optional: true

  validate :exactly_one_creator

  has_one_attached :file, analyze: :lazily

  has_many :content_body_uploads
  has_many :content_bodies, through: :content_body_uploads

  # Not `where.missing` — the bind table is keyless; the offset keeps
  # PostgreSQL on one indexed existence probe per bounded source row.
  scope :unbound, lambda {
    where.not(
      ContentBodyUpload
        .where("content_body_uploads.content_upload_id = content_uploads.id")
        .offset(0).arel.exists
    )
  }

  delegate :filename, :byte_size, to: :file

  # Active Storage/Marcel reports RIFF/WAVE as audio/x-wav while the provider
  # catalog and byte detector use the IANA spelling. Normalize that library
  # boundary once so every internal consumer sees the catalog vocabulary.
  def content_type
    type = file.content_type
    CONTENT_TYPE_ALIASES.fetch(type, type)
  end

  # THE ONE RULE the bytes read serves: readable by its CREATOR — the
  # member `show`'s scope — or by a principal who can read a row that
  # NAMES it: the bind table, each body owner answering through the
  # funnel its own REST door uses. A per-row Ruby walk bounded by the
  # bodies naming one upload, short-circuiting on the first readable
  # owner — never a five-way SQL union. An executor creator has no member
  # read, so an uploaded-never-committed capture is nobody's until a
  # result names it.
  def readable_by?(user)
    return true if creating_user_id == user.id

    content_bodies.includes(ContentBody::OWNER_ROLES.keys).any? do |body|
      body.owner_readable_by?(user)
    end
  end

  # Normalize an external reference through the UUID column's own type once at
  # the OneShot input boundary. Returns nil for an unreadable reference.
  def self.canonical_public_id(value)
    type_for_attribute(:public_id).cast(value)
  end

  # Bound rows consume this source budget and advance the continuation before
  # the reference predicate runs. A retained history therefore cannot make
  # one scheduled invocation scan the whole table looking for 500 orphans.
  def self.reap(batch: REAP_BATCH_SIZE, after_created_at: nil, after_id: 0)
    window = reap_window(
      batch: batch, after_created_at: after_created_at, after_id: after_id
    )
    candidates = unbound.where(id: window.map(&:first))
    reaped = candidates.count do |upload|
      upload.destroy!
    end
    Sweeps::Pass.new(
      counts: { scanned: window.length, reaped: reaped },
      cursor: reap_cursor(window, after_created_at: after_created_at, after_id: after_id),
      more: batch.positive? && window.length == batch
    )
  end

  def self.reap_window(batch:, after_created_at:, after_id:)
    relation = where(
      "created_at < NOW() - make_interval(secs => ?)", ORPHAN_GRACE.to_i
    )
    if after_created_at
      relation = relation.where(
        "(content_uploads.created_at, content_uploads.id) > (?, ?)",
        Time.zone.iso8601(after_created_at), after_id
      )
    end

    relation.order(:created_at, :id).limit(batch).pluck(:id, :created_at)
  end

  def self.reap_cursor(window, after_created_at:, after_id:)
    if window.empty?
      [after_created_at, after_id]
    else
      id, created_at = window.last
      [created_at.iso8601(6), id]
    end
  end
  private_class_method :reap_window, :reap_cursor

  private

    # The one arbiter — there is no CHECK; the two FKs are the structural
    # backstop (`PromptDocument#exactly_one_anchor`'s shape).
    def exactly_one_creator
      return if [creating_user_id, creating_executor_id].count(&:present?) == 1

      errors.add(:base, :exactly_one_creator)
    end
end
