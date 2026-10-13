require "cppjieba_rb"
require "set"

module Nexus
  # An unordered keyword index: Chinese search-mode segmentation and English
  # stemming, with PostgreSQL's dictionaries as the common write/query codec.
  # Bounded vectors are only intermediate values. Their union is a text array,
  # so a legal long body never meets tsvector's one-megabyte representation cap.
  module SearchTerms
    CHUNK_BYTES = 8_192

    def self.for(texts, connection:)
      terms = Set.new
      buffers = { true => +"", false => +"" }
      texts.each do |text|
        text.scan(/\p{Han}+|[^\p{Han}]+/).each do |run|
          chinese = /\A\p{Han}/.match?(run)
          words = chinese ? CppjiebaRb.segment(run, mode: :query) : run.scan(/[\p{L}\p{N}_]+/)
          buffer = buffers.fetch(chinese)
          words.each do |word|
            # PostgreSQL does not index lexemes of 2 KiB or more. Keep that
            # lexical rule, without chopping one token into invented words.
            next if word.bytesize >= 2_048

            if buffer.bytesize + word.bytesize + 1 > CHUNK_BYTES
              normalize(connection, buffer, chinese, terms)
              buffer.clear
            end
            buffer << word << " "
          end
        end
      end
      buffers.each do |chinese, buffer|
        normalize(connection, buffer, chinese, terms) unless buffer.empty?
      end
      terms.to_a.sort
    end

    def self.normalize(connection, text, chinese, terms)
      config = chinese ? "simple" : "english"
      sql = "SELECT unnest(tsvector_to_array(to_tsvector('#{config}', #{connection.quote(text)})))"
      terms.merge(connection.select_values(sql))
    end
    private_class_method :normalize
  end
end
