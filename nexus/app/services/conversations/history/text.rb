module Conversations
  module History
    module Text
      # Match Chinese literal terms and English stem prefixes in the original
      # words, without another SQL query per word or normalization of the whole
      # response. Rare non-prefix stemming falls back to the initial excerpt.
      # Entries are streamed so an accumulated steer body need not fit in memory.
      def self.excerpt(body, limit:, terms: nil)
        prefix = +""
        pattern = terms && Regexp.union(terms.map do |term|
          /\p{Han}/.match?(term) ? /#{Regexp.escape(term)}/i : /(?<![[:alnum:]_])#{Regexp.escape(term)}/i
        end)
        parts = body.searchable_texts
        loop do
          part = parts.next
          if pattern && (match = pattern.match(part))
            start = [match.begin(0) - limit / 4, 0].max
            return [part[start, limit], start.positive? || part.length > limit || prefix.present? || more?(parts)]
          end
          prefix << "\n" unless prefix.empty? || prefix.length > limit
          remaining = limit + 1 - prefix.length
          prefix << part.first(remaining) if remaining.positive?
          break if !pattern && prefix.length > limit
        end
        [prefix.first(limit), prefix.length > limit]
      end

      def self.more?(parts)
        parts.peek
        true
      rescue StopIteration
        false
      end
      private_class_method :more?
    end
  end
end
