module Conversations
  module History
    # Search the current visible timeline, not execution requests or generated
    # compaction context. Array containment uses the existing owners' GIN indexes.
    class Search
      EXCERPT_CHARACTERS = 500

      def self.call(...) = new(...).call

      def initialize(workspace:, user:, query:, archived: "exclude", include_auxiliary: false, limit: 20, after: nil)
        @workspace, @user, @query = workspace, user, query
        @archived, @include_auxiliary, @limit = archived, include_auxiliary, limit
        @after = Cursor.decode(after)
      end

      def call
        terms = ApplicationRecord.with_connection do |connection|
          Nexus::SearchTerms.for([@query], connection: connection)
        end
        return { matches: [], pagination: { next_after: nil } } if terms.empty?

        rows = ApplicationRecord.with_connection do |connection|
          connection.select_all(sql(connection, terms)).to_a
        end
        more = rows.length > @limit
        rows = rows.first(@limit)
        bodies = ContentBody.where(id: rows.filter_map { |row| row["body_id"] }).index_by(&:id)
        { matches: rows.map { |row| present(row, bodies, terms) },
          pagination: { next_after: more ? Cursor.encode(rows.last) : nil } }
      end

      private

        def visible_conversations
          scope = Conversation.visible_to(@user, workspace: @workspace)
          scope = scope.unarchived if @archived == "exclude"
          scope = scope.archived if @archived == "only"
          scope = scope.working.where(parent_conversation_id: nil) unless @include_auxiliary
          scope
        end

        def sql(connection, terms)
          array = "ARRAY[#{terms.map { |term| connection.quote(term) }.join(",")}]::text[]"
          cursor = if @after
            "WHERE (anchor, conversation_public_id, field) < " \
              "(#{connection.quote(@after[0])}::uuid, #{connection.quote(@after[1])}::uuid, #{connection.quote(@after[2])})"
          end
          <<~SQL
            WITH readable AS NOT MATERIALIZED (#{visible_conversations.select(:id, :public_id, :title, :search_terms).to_sql}),
            body_hits AS (
              SELECT b.id AS body_id, b.role AS field, t.id AS turn_id, t.conversation_id,
                t.public_id AS turn_public_id, t.position, t.visibility, t.deleted_at,
                v.public_id AS variant_public_id
              FROM content_bodies b
              JOIN conversation_turn_variants v ON v.id = b.conversation_turn_variant_id AND v.deleted_at IS NULL
              JOIN conversation_turns t ON t.active_variant_id = v.id
              WHERE b.search_terms @> #{array} AND b.sealed_at IS NOT NULL
                AND b.conversation_turn_variant_id IS NOT NULL
                AND b.role IN ('prompt', 'content', 'steers') AND t.kind <> 'compaction_summary'
            ), hits AS (
              SELECT c.public_id AS conversation_public_id, c.title,
                h.turn_public_id, h.variant_public_id, h.position, h.field, false AS inherited,
                h.body_id, h.turn_public_id AS anchor
              FROM body_hits h JOIN readable c ON c.id = h.conversation_id
              WHERE h.deleted_at IS NULL AND h.visibility IN ('visible', 'excluded_from_context')
              UNION ALL
              SELECT c.public_id, c.title, h.turn_public_id, h.variant_public_id, h.position,
                h.field, true, h.body_id, h.turn_public_id
              FROM body_hits h
              JOIN conversation_ancestries a ON a.ancestor_conversation_id = h.conversation_id
                AND h.position <= a.boundary_position
              JOIN readable c ON c.id = a.conversation_id
              LEFT JOIN conversation_turn_overrides o ON o.conversation_id = c.id AND o.conversation_turn_id = h.turn_id
              WHERE o.deleted_at IS NULL AND COALESCE(o.visibility, 'visible') IN ('visible', 'excluded_from_context')
              UNION ALL
              SELECT c.public_id, c.title, NULL::uuid, NULL::uuid, NULL::bigint,
                'title', false, NULL::bigint, c.public_id
              FROM readable c WHERE c.search_terms @> #{array}
            )
            SELECT * FROM hits #{cursor}
            ORDER BY anchor DESC, conversation_public_id DESC, field DESC LIMIT #{@limit + 1}
          SQL
        end

        def present(row, bodies, terms)
          body = bodies[row["body_id"]]
          text, truncated = body ? Text.excerpt(body, limit: EXCERPT_CHARACTERS, terms: terms) : [row.fetch("title"), false]
          row.except("body_id", "anchor").merge("excerpt" => text, "truncated" => truncated)
        end
    end
  end
end
