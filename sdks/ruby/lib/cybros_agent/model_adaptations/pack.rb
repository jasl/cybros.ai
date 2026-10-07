module CybrosAgent
  module ModelAdaptations
    # THE LOADED PACK: the tables and the rows, LOCAL rows first (the
    # listing order `ids` prints, never the resolution's). `for` resolves a
    # kernel model `ref` to its row by the REFERENCE (`ModelPattern`: the
    # ref minus its lane segment) in two tiers. OWN rows — local rows whose
    # id replaces no gem row, the operator's per-model overrides — answer
    # first, the most specific entry winning. Then the STANDING rows — the
    # gem's, a local row of a gem row's id standing in that row's place —
    # the most specific entry winning and, on the same entry, the local
    # row. Else `default`. The loader refuses one entry on two rows of a
    # source, so each tier's winner is unique and file order never
    # decides; a gem row rewritten as a local copy of its id keeps its
    # entries in its tier and moves no reference. A ref MUST carry its lane
    # segment (`ModelPattern.reference` refuses one that does not); `nil`
    # (no model) is `default`.
    class Pack
      attr_reader :presets, :rows

      def initialize(presets:, rows:, gem_ids:)
        @presets = presets
        @rows = rows.freeze
        @by_id = rows.to_h { |row| [row.id, row] }.freeze
        @own, @standing = rows.partition { |row| row.local? && !gem_ids.include?(row.id) }.map(&:freeze)
      end

      def row(id) = @by_id[id.to_s]

      def ids = rows.map(&:id)

      def default = @by_id.fetch(DEFAULT_ROW)

      def for(model_ref)
        if model_ref.nil?
          default
        else
          reference = ModelPattern.reference(model_ref)
          best(@own, reference) || best(@standing, reference) || default
        end
      end

      def gem_rows = rows.select(&:gem?)

      def local_rows = rows.select(&:local?)

      # The row's universe over the kernel's fetched definitions (`Styles`).
      def apply(definitions, row, templates: {})
        Styles.apply(definitions, row, presets: presets, templates: templates)
      end

      def alias_entries(row, templates: {})
        Styles.alias_entries(row, presets: presets, templates: templates)
      end

      private

        # The tier's row with the greatest (specificity, local over gem), or
        # nil when no entry of the tier matches.
        def best(tier, reference)
          tier.filter_map { |row| row.specificity(reference)&.then { |rank| [[rank, row.local? ? 1 : 0], row] } }
            .max_by(&:first)&.last
        end
    end
  end
end
