# Bounded age-out over the (created_at, id) frontier by the database clock.
# Storage bound only: the accepting door already refuses what the window has
# expired, so nothing depends on a reap having run.
module AgeReapable
  extend ActiveSupport::Concern

  included do
    scope :older_than, ->(age) { where("created_at < NOW() - make_interval(secs => ?)", age.to_i) }
  end

  class_methods do
    # The ids are materialized before the DELETE so the statement is bounded
    # and index-ordered from the oldest acceptance; answers the count reaped.
    def reap(batch: 1_000, retention: self::RETENTION)
      ids = older_than(retention).order(:created_at, :id).limit(batch).pluck(:id)

      where(id: ids).delete_all
    end
  end
end
