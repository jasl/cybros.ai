class Conversation
  # The one read filter behind the timeline listing and context assembly.
  # Local turns read their own columns; inherited turns read
  # COALESCE(override, default) and never the shared row's view columns. ORDER BY position is the whole merge.
  class Timeline
    SURFACE_VISIBILITIES = {
      timeline: %w[visible excluded_from_context],
      assembly: %w[visible],
    }.freeze

    Entry = Data.define(:turn, :inherited, :visibility) do
      def position = turn.position
    end

    def initialize(conversation)
      @conversation = conversation
    end

    # `after_position`/`before_position` are exclusive cursors, at most one
    # given; `newest:` takes the newest `limit` rows so a recent window never
    # loads the whole reachable timeline.
    def entries(surface:, after_position: nil, before_position: nil, limit: nil,
                from_position: nil, newest: false, include_hidden: false, include_summaries: true)
      relation = surface_scope(surface, include_hidden: include_hidden)
      relation = relation.where.not(kind: "compaction_summary") unless include_summaries
      relation = relation.where(conversation_turns: { position: (after_position + 1).. }) if after_position
      # INCLUSIVE, unlike `after_position`, because the compaction cut
      # keeps the summary itself: the boundary turn is the newest thing
      # the assembly reads, not the last thing it drops.
      relation = relation.where(conversation_turns: { position: from_position.. }) if from_position
      descending = newest || !before_position.nil?
      if before_position
        relation = relation.where(conversation_turns: { position: ...before_position })
      end
      relation = relation.reorder("conversation_turns.position DESC") if descending
      relation = relation.limit(limit) if limit

      rows = relation.to_a
      rows.reverse! if descending
      rows.map do |turn|
        entry_for(turn)
      end
    end

    # Point reads use the same effective view as windows, including a fork's
    # override. Neither a known UUID nor an input receipt bypasses concealment.
    def entry(public_id:, include_hidden: false)
      turn = surface_scope(:timeline, include_hidden: include_hidden).find_by(public_id: public_id)
      entry_for(turn) if turn
    end

    def materialized_entry(input_public_id:, include_hidden: false)
      turn = surface_scope(:timeline, include_hidden: include_hidden).find_by(input_public_id: input_public_id)
      entry_for(turn) if turn
    end

    # The compaction cut, derived in one indexed query rather than stored, so
    # it survives a fork and a `before_position` window landing before a
    # summary. Only a settled summary cuts — a running or failed one stands in for nothing.
    def compaction_position(surface:, before_position: nil, kind:, status: "completed")
      relation = surface_scope(surface).where(kind: kind, status: status)
      relation = relation.where(conversation_turns: { position: ...before_position }) if before_position
      relation.reorder("conversation_turns.position DESC").limit(1).pick(:position)
    end

    # Counts context, not turns: a contentless turn (a failed reply, a
    # canceled run) is not lost history — a reply that kept its seed is
    # context even without an answer, and counts once with both.
    def content_bearing_count(surface:, before_position: nil, from_position: nil)
      relation = surface_scope(surface).joins(content_body_join_sql)
      relation = relation.where(conversation_turns: { position: ...before_position }) if before_position
      relation = relation.where(conversation_turns: { position: from_position.. }) if from_position
      relation.unscope(:select).unscope(:order).count("DISTINCT conversation_turns.id")
    end

    # THE REACH, as one Arel predicate over `conversation_turns`: local rows,
    # plus each ancestor's rows up to its inclusive bound. An empty-prefix
    # pin (bound -1) contributes nothing and costs nothing. Public because
    # it is the funnel's one definition of "reachable" — the timeline's own
    # reads and `Conversations::RunnerEffectsAt` read the same rows through it.
    def reach
      inherited = @conversation.conversation_ancestries
        .pluck(:ancestor_conversation_id, :boundary_position)
        .map do |ancestor_id, bound|
          Arel::Nodes::Grouping.new(
            turns[:conversation_id].eq(ancestor_id).and(turns[:position].lteq(bound))
          )
        end
      # `Node#or` rather than the `Or` node's constructor, whose arity has
      # changed across Rails versions.
      [local_turn, *inherited].reduce(:or)
    end

    def visible_turns(surface: :timeline)
      surface_scope(surface).where.not(kind: "compaction_summary")
    end

    private

      def entry_for(turn)
        Entry.new(turn: turn, inherited: turn.conversation_id != @conversation.id,
          visibility: turn[:effective_visibility])
      end

      def surface_scope(surface, include_hidden: false)
        visibilities = SURFACE_VISIBILITIES.fetch(surface)
        visibilities += ["hidden"] if include_hidden
        reachable_turns
          .where(effective_deleted_at.eq(nil))
          .where(effective_visibility.in(visibilities))
      end

      def content_body_join_sql
        <<~SQL
          INNER JOIN content_bodies
            ON content_bodies.conversation_turn_variant_id = conversation_turns.active_variant_id
           AND content_bodies.role IN ('content', 'prompt')
        SQL
      end

      def reachable_turns
        ConversationTurn
          .joins(overlay_join)
          .where(reach)
          .select("conversation_turns.*", effective_visibility.as("effective_visibility"))
          .order("conversation_turns.position ASC")
      end

      def turns = ConversationTurn.arel_table

      def overrides = ConversationTurnOverride.arel_table

      def local_turn = turns[:conversation_id].eq(@conversation.id)

      # This conversation's own view row for an inherited turn; a local turn has none.
      def overlay_join
        turns.join(overrides, Arel::Nodes::OuterJoin)
          .on(overrides[:conversation_id].eq(@conversation.id)
            .and(overrides[:conversation_turn_id].eq(turns[:id])))
          .join_sources
      end

      def effective_visibility
        Arel::Nodes::Case.new
          .when(local_turn).then(turns[:visibility])
          .else(Arel::Nodes::NamedFunction.new(
            "COALESCE", [overrides[:visibility], Arel::Nodes.build_quoted("visible")]
          ))
      end

      def effective_deleted_at
        Arel::Nodes::Case.new
          .when(local_turn).then(turns[:deleted_at])
          .else(overrides[:deleted_at])
      end
  end
end
