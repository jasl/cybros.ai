module Conversations
  module History
    class Read
      MAX_CHARACTERS = 12_000
      FIELD_CHARACTERS = 2_000
      FIELD_ORDER = %w[prompt steers content].freeze

      def self.call(...) = new(...).call

      def initialize(conversation:, around_turn_public_id: nil, after_position: nil, before_position: nil, limit: 20)
        @conversation, @around = conversation, around_turn_public_id
        @after, @before, @limit = after_position, before_position, limit
      end

      def call
        entries = window
        bodies_by_variant = ContentBody.where(conversation_turn_variant_id: entries.map { |entry| entry.turn.active_variant_id },
          role: ContentBody::Searchable::ROLES).order(:role).group_by(&:conversation_turn_variant_id)
        remaining = MAX_CHARACTERS
        truncated = false
        turns = allocation_order(entries).map do |entry|
          turn = entry.turn
          result = turn.slice(:public_id, :position, :kind, :role, :created_at)
          result[:truncated] = false
          bodies = bodies_by_variant.fetch(turn.active_variant_id, [])
          bodies.sort_by { |body| FIELD_ORDER.index(body.role) }.each do |body|
            text, cut = Text.excerpt(body, limit: [remaining, FIELD_CHARACTERS].min)
            result[body.role] = text
            result[:truncated] ||= cut
            remaining -= text.length
          end
          truncated ||= result[:truncated]
          result
        end.sort_by { |turn| turn.fetch("position") }
        { conversation: @conversation.slice(:public_id, :title), turns: turns,
          pagination: { before_position: entries.first&.position, after_position: entries.last&.position,
            has_older: more?(before_position: entries.first&.position),
            has_newer: more?(after_position: entries.last&.position) }, truncated: truncated }
      end

      private

        # Allocate the bounded text nearest the requested address first, then
        # return chronological rows. Otherwise long old messages can consume
        # the whole page before the target or latest answer is rendered.
        def allocation_order(entries)
          if @around
            entries.sort_by { |entry| [(entry.position - @around_position).abs, -entry.position] }
          else
            @after ? entries : entries.reverse
          end
        end

        def window
          if @around
            # Reach alone is insufficient: the target must survive this view's
            # concealment filter, exactly like every other timeline read.
            target = @conversation.timeline.visible_turns.find_by!(public_id: @around)
            @around_position = target.position
            before = @conversation.timeline.entries(surface: :timeline, include_summaries: false,
              before_position: target.position, limit: @limit / 2)
            after = @conversation.timeline.entries(surface: :timeline, include_summaries: false,
              from_position: target.position, limit: @limit - before.length)
            before + after
          else
            @conversation.timeline.entries(surface: :timeline, include_summaries: false, after_position: @after,
              before_position: @before, newest: @after.nil? && @before.nil?, limit: @limit)
          end
        end

        def more?(**cursor)
          return false if cursor.values.first.nil?

          @conversation.timeline.entries(surface: :timeline, include_summaries: false, **cursor, limit: 1).any?
        end
    end
  end
end
