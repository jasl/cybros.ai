class ContentBody
  module Searchable
    extend ActiveSupport::Concern

    ROLES = %w[prompt content steers].freeze

    included do
      before_save :prepare_search_terms, if: :search_sealing?
    end

    def searchable_texts
      return enum_for(__method__) unless block_given?
      return unless conversation_turn_variant_id && ROLES.include?(role)

      if role == "steers"
        each_search_entry do |entry|
          payload = entry.content_fragment.payload
          if payload.key?("parts")
            payload.fetch("parts").each do |part|
              yield part.fetch("text") if part["type"] == "text"
            end
          elsif payload.key?("text")
            yield payload.fetch("text")
          end
        end
      elsif readable_text
        yield readable_text
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
        conversation_turn_variant_id && ROLES.include?(role) &&
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
