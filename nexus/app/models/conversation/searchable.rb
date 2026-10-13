class Conversation
  module Searchable
    extend ActiveSupport::Concern

    included do
      before_save :prepare_search_terms, if: :will_save_change_to_title?
    end

    private

      def title_search_terms
        self.class.with_connection { |connection| Nexus::SearchTerms.for([title.to_s], connection: connection) }
      end

      def prepare_search_terms
        self.search_terms = title_search_terms
      end
  end
end
