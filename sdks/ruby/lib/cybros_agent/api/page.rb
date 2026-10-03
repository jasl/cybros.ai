module CybrosAgent
  module Api
    # One manually paged list answer: the typed `items` of this
    # page and the opaque `next_after` cursor — nil when the collection is
    # exhausted. A client never parses a cursor; it hands the value back to
    # the same list call's `after:`.
    Page = Data.define(:items, :next_after)
  end
end
