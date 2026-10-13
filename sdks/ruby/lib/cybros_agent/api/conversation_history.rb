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
      :public_id, :position, :kind, :role, :status, :created_at, :prompt, :content, :steers, :truncated
    ) do
      def truncated? = truncated
    end

    ConversationHistoryExecution = Data.define(
      :turn_public_id, :variant_public_id, :active, :status, :run_public_id, :run_status,
      :rounds, :next_before, :has_older, :truncated, :details_pruned_at, :attention_reason, :failure_reason
    ) do
      def active? = active
      def has_older? = has_older
      def truncated? = truncated

      def to_h
        super.except(:next_before, :has_older).merge(rounds: rounds.map(&:to_h),
          pagination: { next_before: next_before, has_older: has_older }).compact
      end
    end

    ConversationHistoryPage = Data.define(
      :conversation, :turns, :before_position, :after_position, :has_older, :has_newer, :truncated,
      :execution, :execution_included
    ) do
      include Enumerable
      def each(&) = turns.each(&)
      def length = turns.length
      def has_older? = has_older
      def has_newer? = has_newer
      def truncated? = truncated
      def execution_included? = execution_included

      def to_h
        result = { conversation: conversation.to_h, turns: turns.map(&:to_h), truncated: truncated,
          pagination: { before_position: before_position, after_position: after_position,
            has_older: has_older, has_newer: has_newer } }
        result[:execution] = execution&.to_h if execution_included?
        result
      end
    end

    module ConversationHistoryProjections
      include RunProjections

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
          public_id: :string, position: :integer, kind: :string, role: :string, status: :string, created_at: :string,
          prompt: :optional_string, content: :optional_string, steers: :optional_string, truncated: :boolean,
        },
        ConversationHistoryExecution => {
          turn_public_id: :string, variant_public_id: :string, active: :boolean, status: :string,
          run_public_id: :string, run_status: :string, rounds: [:shapes, ThreadRow],
          next_before: [:nullable_string, "pagination", "next_before"],
          has_older: [:boolean, "pagination", "has_older"], truncated: :boolean, details_pruned_at: :optional_string,
          attention_reason: :optional_string, failure_reason: :optional_string,
        },
        ConversationHistoryPage => {
          conversation: [:shape, ConversationHistoryTitle], turns: [:shapes, ConversationHistoryTurn],
          before_position: [:optional_integer, "pagination", "before_position"],
          after_position: [:optional_integer, "pagination", "after_position"],
          has_older: [:boolean, "pagination", "has_older"], has_newer: [:boolean, "pagination", "has_newer"],
          truncated: :boolean,
          execution: [:optional_shape, ConversationHistoryExecution], execution_included: ->(hash) { hash.key?("execution") },
        },
      }.freeze
    end

    # A bounded text window with opt-in execution previews. Callers choose
    # each history or execution window explicitly; reads never paginate themselves.
    class ConversationHistoryContext
      include ConversationHistoryProjections
      include Fields

      def initialize(dispatch:, path:)
        @dispatch, @path = dispatch, path
      end

      def list(around_turn_public_id: nil, after_position: nil, before_position: nil, limit: nil,
               include_execution: nil, execution_before: nil, execution_prefix: nil)
        if [around_turn_public_id, after_position, before_position].compact.length > 1
          raise ArgumentError, "give around_turn_public_id, after_position or before_position, never more than one"
        end

        shape(ConversationHistoryPage, @dispatch.call(@path,
          params: query(around_turn_public_id:, after_position:, before_position:, limit:,
            include_execution:, execution_before:, execution_prefix:)))
      end
    end
  end
end
