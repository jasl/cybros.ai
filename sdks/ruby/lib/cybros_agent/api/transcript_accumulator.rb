module CybrosAgent
  module Api
    # THE FIVE LAWS OF THE TRANSCRIPT FEED, IN ONE PLACE (runs.md,
    # "the five laws"): deltas append in arrival order, a `stream_reset`
    # throws away what was streamed, the settled body REPLACES what the
    # deltas built, nothing here is durable, and a consumer that
    # re-implements it gets one of them wrong. rho's follower, a console
    # and the webui share this object rather than each holding a string.
    #
    # BOUNDED BUFFER, UNBOUNDED COUNT. `bound` is a memory ceiling on what
    # is HELD — a preview is allowed to drop its head, and a follower that
    # grew a string for the length of a run was a leak. `length` is every
    # byte accumulated since the last reset, and it is what makes the
    # settle comparison exact for a reply longer than the ceiling: without
    # it a long reply reads as a REPLACEMENT and a terminal reprints the
    # whole thing under a marker line that lied.
    #
    # It holds no feed, opens no socket and knows no item type: the caller
    # reads the type and calls the method, because the vocabulary of that
    # feed grows and this object must not be the thing that predates it.
    class TranscriptAccumulator
      DEFAULT_BOUND = 64 * 1024

      # A UTF-8 continuation byte: `10xxxxxx`. Trimming the head by bytes
      # can land inside a character, and what is held has to stay
      # printable AND serializable — a JSON generator refuses an invalid
      # string, which would turn a long reply into a 500 on the daemon's
      # own snapshot route.
      CONTINUATION_BYTES = (0x80..0xBF).freeze

      EMPTY = "".freeze

      attr_reader :length, :key

      def initialize(bound: DEFAULT_BOUND)
        @bound = bound
        @buffer = utf8_buffer
        @length = 0
        @key = nil
        @replaced = false
      end

      # One delta. `key` is the stream this text belongs to — the round's
      # task key, or a direct reply's variant — and a key that differs
      # from the one held RESETS first: a new answer never concatenates
      # onto the previous one. Answers the text it appended, so a caller
      # prints exactly what was accumulated without re-deriving it.
      def accumulate(text, key: nil)
        reset(key: key) unless key.nil? || key == @key
        text = utf8(text)
        return nil if text.nil? || text.empty?

        @buffer << text
        @length += text.bytesize
        trim
        text.freeze
      end

      # A `stream_reset`, a new turn, or a feed reopened after a loss: what
      # was streamed is no longer known to be a prefix of anything.
      def reset(key: nil)
        @buffer = utf8_buffer
        @length = 0
        @replaced = false
        @key = key
        nil
      end

      # THE SETTLED BODY ARRIVES. Answers the UNPRINTED REMAINDER, so a
      # terminal that already showed the deltas adds only what is left.
      # A continuation is decided on the COUNT and the tail — the buffer
      # is a suffix of everything accumulated, so the body continues this
      # stream when it is at least as long and ends the same way there.
      def replace_on_settle(text)
        replace_snapshot(text)
      end

      # A re-join or poll can carry only the tail of a running transcript.
      # `length` still counts the whole stream. Compare the shared window
      # before returning its new bytes: a missed reset can replace a reply
      # with one of the same length, so the count alone cannot decide.
      def replace_snapshot(text, length: nil)
        text = utf8(text)
        return EMPTY if text.nil?

        total = [length.to_i, text.bytesize].max
        growth = total - @length
        @replaced = @length.positive? && !continuation?(text, growth)
        count = @replaced ? text.bytesize : [growth, text.bytesize].min
        remainder = text.byteslice(text.bytesize - count, count).to_s
        @buffer = utf8_buffer << text
        @length = total
        trim
        utf8(remainder).freeze
      end

      # The last snapshot or settle replaced what was streamed rather than continuing
      # it — the one fact a printer needs to decide whether to say so.
      def replaced? = @replaced

      def text = @buffer.dup.freeze

      def empty? = @buffer.empty?

      private

        def continuation?(text, growth)
          return false if growth.negative? || growth > text.bytesize

          overlap = text.byteslice(0, text.bytesize - growth).to_s
          overlap.empty? || @buffer.end_with?(overlap) || overlap.end_with?(@buffer)
        end

        def utf8_buffer = String.new(encoding: Encoding::UTF_8)

        def utf8(text)
          return nil if text.nil?

          text.to_s.dup.force_encoding(Encoding::UTF_8)
        end

        def trim
          excess = @buffer.bytesize - @bound
          return if excess <= 0

          tail = @buffer.byteslice(excess..).to_s
          drop = 0
          drop += 1 while drop < tail.bytesize && CONTINUATION_BYTES.cover?(tail.getbyte(drop))
          @buffer = utf8_buffer << tail.byteslice(drop..).to_s
        end
    end
  end
end
