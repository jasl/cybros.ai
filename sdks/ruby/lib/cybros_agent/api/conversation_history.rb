module CybrosAgent
  module Api
    ConversationSearchMatch = Data.define(
      :conversation_public_id, :title, :turn_public_id, :variant_public_id, :position,
      :field, :inherited, :excerpt, :truncated
    ) do
      def inherited? = inherited
      def truncated? = truncated
    end

    ConversationSearchPage = Data.define(:matches, :next_after) do
      include Enumerable
      def each(&) = matches.each(&)
      def length = matches.length
    end

    ConversationHistoryTitle = Data.define(:public_id, :title)
    ConversationHistoryTurn = Data.define(
      :public_id, :position, :kind, :role, :created_at, :prompt, :content, :steers, :truncated
    ) do
      def truncated? = truncated
    end

    ConversationHistoryPage = Data.define(
      :conversation, :turns, :before_position, :after_position, :has_older, :has_newer, :truncated
    ) do
      include Enumerable
      def each(&) = turns.each(&)
      def length = turns.length
      def has_older? = has_older
      def has_newer? = has_newer
      def truncated? = truncated
    end

    module ConversationHistoryProjections
      include Parsing

      SHAPES = {
        ConversationSearchMatch => {
          conversation_public_id: :string, title: :optional_string,
          turn_public_id: :optional_string, variant_public_id: :optional_string, position: :optional_integer,
          field: :string, inherited: :boolean, excerpt: :optional_string, truncated: :boolean,
        },
        ConversationSearchPage => {
          matches: [:shapes, ConversationSearchMatch], next_after: [:nullable_string, "pagination", "next_after"],
        },
        ConversationHistoryTitle => { public_id: :string, title: :optional_string },
        ConversationHistoryTurn => {
          public_id: :string, position: :integer, kind: :string, role: :string, created_at: :string,
          prompt: :optional_string, content: :optional_string, steers: :optional_string, truncated: :boolean,
        },
        ConversationHistoryPage => {
          conversation: [:shape, ConversationHistoryTitle], turns: [:shapes, ConversationHistoryTurn],
          before_position: [:optional_integer, "pagination", "before_position"],
          after_position: [:optional_integer, "pagination", "after_position"],
          has_older: [:boolean, "pagination", "has_older"], has_newer: [:boolean, "pagination", "has_newer"],
          truncated: :boolean,
        },
      }.freeze
    end

    # A bounded text window for recall. It does not fetch execution traces
    # or silently paginate; callers choose the next window from the answer.
    class ConversationHistoryContext
      include ConversationHistoryProjections
      include Fields

      def initialize(dispatch:, path:)
        @dispatch, @path = dispatch, path
      end

      def list(around_turn_public_id: nil, after_position: nil, before_position: nil, limit: nil)
        if [around_turn_public_id, after_position, before_position].compact.length > 1
          raise ArgumentError, "give around_turn_public_id, after_position or before_position, never more than one"
        end

        shape(ConversationHistoryPage, @dispatch.call(@path,
          params: query(around_turn_public_id:, after_position:, before_position:, limit:)))
      end
    end
  end
end
