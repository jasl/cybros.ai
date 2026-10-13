module Conversations
  module History
    class Read
      MAX_CHARACTERS = 12_000
      FIELD_CHARACTERS = 2_000
      FIELD_ORDER = %w[prompt steers content].freeze

      def self.call(...) = new(...).call

      def initialize(conversation:, user:, conversations: nil, around_turn_public_id: nil,
                     after_position: nil, before_position: nil, limit: 20, include_execution: false,
                     execution_before: nil, execution_prefix: nil)
        @conversation, @around = conversation, around_turn_public_id
        @after, @before, @limit = after_position, before_position, limit
        @user = user
        @conversations = conversations || Conversation.visible_to(user, workspace: conversation.workspace)
        @include_execution, @execution_before, @execution_prefix = include_execution, execution_before, execution_prefix
        @remaining, @truncated = MAX_CHARACTERS, false
      end

      def call
        entries = window
        @bodies_by_variant = ContentBody.where(conversation_turn_variant_id: entries.map { |entry| entry.turn.active_variant_id },
          role: ContentBody::Searchable::ROLES).order(:role).group_by(&:conversation_turn_variant_id)
        selected = (@around ? entries.find { |entry| entry.position == @around_position } : entries.last) if @include_execution
        # Fund the selected turn, then its newest execution previews, before
        # nearby history. The entire read shares this one text allowance.
        turns = selected ? [turn_body(selected)] : []
        execution = execution_for(selected.turn) if selected
        allocation_order(entries).each { |entry| turns << turn_body(entry) unless entry == selected }
        result = { conversation: @conversation.slice(:public_id, :title), turns: turns.sort_by { |turn| turn.fetch("position") },
          pagination: { before_position: entries.first&.position, after_position: entries.last&.position,
            has_older: more?(before_position: entries.first&.position),
            has_newer: more?(after_position: entries.last&.position) }, truncated: @truncated }
        result[:execution] = execution if @include_execution
        result
      end

      private

        def turn_body(entry)
          turn = entry.turn
          result = turn.slice(:public_id, :position, :kind, :role, :status, :created_at)
          result[:truncated] = false
          @bodies_by_variant.fetch(turn.active_variant_id, []).sort_by { |body| FIELD_ORDER.index(body.role) }.each do |body|
            text, cut = Text.excerpt(body, limit: [@remaining, FIELD_CHARACTERS].min)
            result[body.role] = text
            result[:truncated] ||= cut
            @remaining -= text.length
          end
          @truncated ||= result[:truncated]
          result
        end

        def execution_for(turn)
          candidates = TurnProjection.candidates_for([turn])
          variant = candidates.running_by_turn[turn.id] || candidates.by_id[turn.active_variant_id]
          return nil if variant.nil?

          # An inherited answer is readable in the fork, but that does not
          # grant the source Run's execution or widen the caller's reach.
          agent_run = AgentRun.where(workspace_id: @conversation.workspace_id).listable.readable_by(@user)
            .joins(:conversation).merge(@conversations)
            .find_by(conversation_turn_variant_id: variant.id)
          return nil if agent_run.nil?

          result = { turn_public_id: turn.public_id, variant_public_id: variant.public_id,
            active: variant.id == turn.active_variant_id, status: variant.status,
            run_public_id: agent_run.public_id, run_status: agent_run.status,
            attention_reason: agent_run.attention_reason, failure_reason: agent_run.failure_reason,
            details_pruned_at: agent_run.details_pruned_at || variant.details_pruned_at,
            rounds: [], pagination: { next_before: nil, has_older: false }, truncated: false }.compact
          unless result[:details_pruned_at]
            page = AgentRuns::Transcript.call(agent_run: agent_run, before: @execution_before, prefix: @execution_prefix)
            raise ActiveRecord::RecordNotFound if page.refused?

            result[:rounds] = page.rounds
            result[:pagination] = { next_before: page.next_before, has_older: page.has_older }
            page.rounds.reverse_each do |round|
              result[:truncated] = preview(round, :text_preview) || result[:truncated]
              result[:truncated] = preview(round[:error], :detail) || result[:truncated] if round[:error]
              round.fetch(:calls).fetch(:items).reverse_each do |call|
                # Presentation-only executor fields never become model context.
                call.delete(:title)
                call.delete(:metadata)
                result[:truncated] = preview(call, :output_preview) || result[:truncated]
              end
            end
          end
          @truncated ||= result[:truncated]
          result
        end

        def preview(row, key)
          return false unless row.key?(key)

          text = row.fetch(key)
          row[key] = text.first([@remaining, FIELD_CHARACTERS].min)
          @remaining -= row.fetch(key).length
          row.fetch(key).length < text.length
        end

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
