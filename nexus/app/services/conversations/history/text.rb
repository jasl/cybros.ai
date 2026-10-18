module Conversations
  module History
    module Text
      # Match Chinese literal terms and English stem prefixes in the original
      # words, without another SQL query per word or normalization of the whole
      # response. Rare non-prefix stemming falls back to the initial excerpt.
      # Entries are streamed so an accumulated steer body need not fit in memory.
      def self.excerpt(body, limit:, terms: nil)
        prefix = +""
        first_location = nil
        pattern = terms && Regexp.union(terms.map do |term|
          /\p{Han}/.match?(term) ? /#{Regexp.escape(term)}/i : /(?<![[:alnum:]_])#{Regexp.escape(term)}/i
        end)
        parts = body.searchable_text_parts
        loop do
          segment = parts.next
          part = segment.fetch(:text)
          first_location ||= Location.encode(**segment.except(:text))
          if pattern && (match = pattern.match(part))
            start = [match.begin(0) - limit / 4, 0].max
            return [part[start, limit], start.positive? || part.length > limit || prefix.present? || more?(parts),
              Location.encode(**segment.except(:text), character_offset: start)]
          end
          prefix << "\n" unless prefix.empty? || prefix.length > limit
          remaining = limit + 1 - prefix.length
          prefix << part.first(remaining) if remaining.positive?
          break if !pattern && prefix.length > limit
        end
        [prefix.first(limit), prefix.length > limit, first_location]
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
