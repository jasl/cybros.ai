# One immutable deduplicated JSON payload. The digest is account-salted,
# so the same bytes converge to one row inside one trust domain and
# never across two.
class ContentFragment < ApplicationRecord
  # A fragment is reference-counted by the existence of entries, so writers
  # strand rather than delete; the grace keeps adopt-vs-reap safe in the
  # writer's favour.
  ORPHAN_GRACE = 1.day
  REAP_BATCH_SIZE = 1_000

  attr_readonly :account_id, :digest, :payload

  belongs_to :account

  has_many :content_body_entries, dependent: :restrict_with_exception

  # The orphan reaper loses every adopt-vs-reap race by design: the scan is unlocked and the
  # RESTRICT FK refuses the contested row, which is an outcome, not an error. The (created_at,
  # id) window comes before the anti-join.
  def self.reap(batch: REAP_BATCH_SIZE, after_created_at: nil, after_id: 0)
    window = reap_window(
      batch: batch, after_created_at: after_created_at, after_id: after_id
    )
    candidates = where(id: window.map(&:first))
      .where.not(referencing_entries.arel.exists)
      .order(:created_at, :id).pluck(:id)
    reaped = candidates.count do |id|
      transaction(requires_new: true) do
        where(id: id).delete_all.positive?
      end
    rescue ActiveRecord::StatementInvalid => error
      raise unless Nexus::ForeignKeyViolation.matches?(error, constraint: "fk_rails_0bdf3bbbda")

      # A concurrent entry adoption won. The savepoint has rolled back, so
      # later candidates and the caller's transaction can still proceed.
      false
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
        "(content_fragments.created_at, content_fragments.id) > (?, ?)",
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

  def self.referencing_entries
    # The no-op offset keeps PostgreSQL on one correlated existence probe per
    # window row instead of a hash anti-join over every entry.
    ContentBodyEntry.where(
      "content_body_entries.content_fragment_id = content_fragments.id"
    ).offset(0)
  end
  private_class_method :reap_window, :reap_cursor, :referencing_entries
end
