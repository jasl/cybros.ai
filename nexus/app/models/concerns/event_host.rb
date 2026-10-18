# The narration trait: the one event plane, hosted. The envelope cascades
# its items and the cursor dies with the host; the items carry no
# `dependent` of their own because the envelope owns them.
module EventHost
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :host, dependent: :destroy
    has_many :event_items, as: :host
    has_one :event_cursor, as: :host, dependent: :destroy
  end

  # Allocation and items commit together. Unlike retained items, this head
  # survives expiry so a follower can detect progress it can no longer replay.
  def event_watermark = (event_cursor&.next_sequence || 1) - 1
end
