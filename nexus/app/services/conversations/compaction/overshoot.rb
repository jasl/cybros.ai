module Conversations
  module Compaction
    # How far past the bound a request stood. Bytes give the prune arm its
    # cheap candidate test; a token wall also retains its original count so
    # compressible result text cannot make byte savings masquerade as tokens.
    # A trigger with no count (manual or provider refusal) summarizes.
    class Overshoot < Data.define(:bytes, :tokens)
      BYTES_PER_TOKEN = 4

      class << self
        def bytes(count) = new(bytes: Integer(count))
        def tokens(count)
          count = Integer(count)
          new(bytes: count * BYTES_PER_TOKEN, tokens: count)
        end
      end

      def initialize(bytes:, tokens: nil)
        raise ArgumentError, "an overshoot is a positive count of bytes" unless bytes.positive?

        super
      end
    end
  end
end
