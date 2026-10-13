module Nexus
  # What was dropped, said out loud: a summarizer handed a history that begins
  # mid-sentence with no marker summarizes over the gap. Pure text, read by the
  # one compaction serializer once it has rendered its entries.
  module Elision
    PARTS_ELIDED = "[... %<count>d earlier %<noun>s elided to fit ...]".freeze
    BYTES_ELIDED = "[... %<bytes>d earlier bytes elided to fit ...]".freeze
    JOINER = "\n\n".freeze

    module_function

    # Drops whole parts, oldest first, and says how many; `clamp` underneath
    # handles the one case parts cannot fix — a single part past the budget.
    # The last part is never dropped: no history is not a smaller history.
    def fit(parts, room, noun: "round")
      kept = parts.dup
      dropped = 0
      while kept.length > 1 && joined_size(kept) > room
        kept.shift
        dropped += 1
      end
      text = kept.join(JOINER)
      return clamp(text, room) if dropped.zero?

      # The marker is inside the room: prepending it after clamping overran
      # the bound by its own width.
      note = format(PARTS_ELIDED, count: dropped, noun: "#{noun}(s)")
      body = clamp(text, room - note.bytesize - JOINER.bytesize)
      return clamp(text, room) if body.empty?

      "#{note}#{JOINER}#{body}"
    end

    # Keeps the newest material — what a summary is least able to reconstruct.
    # The marker is inside the room, not added to it.
    def clamp(text, room)
      return "" if room <= 0
      return text if text.bytesize <= room

      note = format(BYTES_ELIDED, bytes: text.bytesize - room)
      keep = room - note.bytesize - JOINER.bytesize
      # Input is valid UTF-8; a tail slice can only split its first
      # character. Drop that incomplete character without inserting one.
      return text.byteslice(text.bytesize - room, room).to_s.scrub("") if keep <= 0

      "#{note}#{JOINER}#{text.byteslice(text.bytesize - keep, keep).scrub("")}"
    end

    def joined_size(parts)
      parts.sum(&:bytesize) + ((parts.length - 1) * JOINER.bytesize)
    end
  end
end
