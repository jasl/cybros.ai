module Conversations
  module Inputs
    # THE ONE READER of a caller's "not before",
    # called by both doors — the member controller and the `send` executor
    # — so the two cannot drift. Two
    # wire spellings, one fact: `deliver_at`, an absolute ISO 8601 time WITH
    # an offset or `Z`; `deliver_in`, a delay from now (`90s`, `20m`, `2h`,
    # `1d`) — hermes' one-shot-by-duration grammar and openclaw's relative
    # form, the references' agreement on the shape of a delay. Exactly one
    # of the two; both resolve to ONE Time here and the row stores
    # `deliver_at` only.
    #
    # A shape check first, anchored and length-capped,
    # because `Time.iso8601` reads a naive stamp in the PROCESS's zone and a
    # six-digit year parses but overflows the column. The wire refuses the
    # naive stamp (the kernel has no zone of the caller's and no
    # naive-means-UTC convention — every timestamp it emits carries `Z`); a
    # CLI that knows the person's zone resolves one before the call.
    # Each door wraps a refusal in its own grammar; the door itself judges
    # the resolved time against its clock (Create's two bounds).
    module DeliverAt
      AT_SHAPE = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|[+-]\d\d:?\d\d)\z/i
      IN_SHAPE = /\A(\d{1,9})([smhd])\z/
      UNIT = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze
      MAX_LENGTH = 40
      # Both spellings at once: the door's own 422, the pack derives it.
      AMBIGUOUS = :deliver_at_ambiguous

      # Exactly one of the two is non-nil; both nil when nothing was said.
      Reading = Data.define(:time, :refusal)

      class << self
        def parse(at: nil, in_: nil, now:)
          return Reading.new(time: nil, refusal: AMBIGUOUS) if at && in_
          return Reading.new(time: nil, refusal: nil) if at.nil? && in_.nil?
          return parse_at(at) if at

          parse_in(in_, now)
        end

        private

          def parse_at(value)
            string = value.to_s
            return refused(:deliver_at_invalid) unless string.length <= MAX_LENGTH && AT_SHAPE.match?(string)

            Reading.new(time: Time.iso8601(string), refusal: nil)
          rescue ArgumentError
            # The shape passed and the calendar refused: a 13th month, a 25th
            # hour (a 30th of February rolls over to March; Ruby's own rule).
            refused(:deliver_at_invalid)
          end

          def parse_in(value, now)
            match = IN_SHAPE.match(value.to_s)
            return refused(:deliver_in_invalid) if match.nil?

            Reading.new(time: now + Integer(match[1], 10) * UNIT.fetch(match[2]), refusal: nil)
          end

          def refused(code) = Reading.new(time: nil, refusal: code)
      end
    end
  end
end
