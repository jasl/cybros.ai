class ContentBody
  module Searchable
    extend ActiveSupport::Concern

    ROLES = %w[prompt content steers].freeze

    included do
      before_save :prepare_search_terms, if: :search_sealing?
    end

    def searchable_texts
      return enum_for(__method__) unless block_given?

      searchable_text_parts.each { |part| yield part.fetch(:text) }
    end

    def searchable_text_parts
      return enum_for(__method__) unless block_given?
      return unless variant_id && ROLES.include?(role)

      if role == "steers"
        each_search_entry do |entry|
          search_entry_parts(entry).each { |part| yield part }
        end
      elsif readable_text
        yield({ text: readable_text, entry_position: nil, part_index: 0 })
      end
    end

    def search_entry_parts(entry)
      return enum_for(__method__, entry) unless block_given?

      payload = entry.content_fragment.payload
      if payload.key?("parts")
        payload.fetch("parts").each_with_index do |part, index|
          yield({ text: part.fetch("text"), entry_position: entry.position, part_index: index }) if part["type"] == "text"
        end
      elsif payload.key?("text")
        yield({ text: payload.fetch("text"), entry_position: entry.position, part_index: 0 })
      end
    end

    private

      def each_search_entry
        position = -1
        loop do
          entries = content_body_entries.where("position > ?", position)
            .reorder(:position).limit(50).includes(:content_fragment).to_a
          break if entries.empty?

          entries.each { |entry| yield entry }
          position = entries.last.position
        end
      end

      def search_sealing?
        variant_id && ROLES.include?(role) &&
          sealed_at.present? && will_save_change_to_sealed_at?
      end

      def prepare_search_terms
        self.search_terms = indexed_search_terms
      end

      def indexed_search_terms
        return [] unless sealed?

        self.class.with_connection { |connection| Nexus::SearchTerms.for(searchable_texts, connection: connection) }
      end
  end
end
