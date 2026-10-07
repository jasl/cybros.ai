module CybrosAgent
  module ModelAdaptations
    # THE UNIVERSE A ROW DECLARES — the pure set function, moved with the
    # tables out of rho's `ToolStyle.apply`. Given the kernel's fetched
    # definitions (the plain render `GET /tools` serves) and a row: the
    # plain entries kept — a plain `task`/`ask`/`spawn`/`send`/
    # `skill` withheld only when `nexus` is absent from the row's styles
    # AND an active preset supersedes it; every other name, a runner's tool
    # among them, under every style — then the active presets' aliases in
    # `words` order, then the row's own `tool_descriptions`, each an alias
    # entry of the SDK's one shape (`ToolCatalog#alias`) for a canonical
    # the catalog carries, its `recut` rendered against the served template
    # (`templates[canonical]`). There is no VIEW half: under one row per
    # boot the view is the whole declaration.
    module Styles
      module_function

      def apply(definitions, row, presets:, templates: {})
        styles = row.tool_style
        declared = names_of(definitions)
        kept = definitions.reject { |entry| withheld?(name_of(entry), styles, presets: presets) }
        carried = alias_specs(row, presets: presets).select { |spec| declared.include?(presets.plain_name(spec.fetch("canonical"))) }
        kept + carried.map { |spec| entry(spec, templates: templates) }
      end

      # The row's alias specs, unfiltered: its styles' preset aliases, then
      # its own description variants.
      def alias_specs(row, presets:)
        presets.aliases_for(row.tool_style) + row.tool_descriptions
      end

      # The row's alias entries, every spec rendered.
      def alias_entries(row, presets:, templates: {})
        alias_specs(row, presets: presets).map { |spec| entry(spec, templates: templates) }
      end

      # ONE alias spec as the compact entry the kernel renders: built by the
      # SDK's one writer of the shape, frozen; a `recut` becomes the entry's
      # `description` — the served template with its anchor replaced.
      def entry(spec, templates: {})
        description = spec["description"] || recut(spec, templates)
        built = CybrosAgent::Api::ToolCatalog.new(dispatch: nil).alias(
          name: spec.fetch("name"), canonical: spec.fetch("canonical"),
          params: spec.fetch("params", {}), omit: spec.fetch("omit", []), description: description
        )
        ModelAdaptations.freeze_deep(built)
      end

      # The anchor must stand in the served template: a moved anchor (or a
      # template the kernel did not serve) is loud, never a silent no-op.
      def recut(spec, templates)
        edit = spec["recut"] or return nil
        name = spec.fetch("name")
        template = templates[spec.fetch("canonical")]
        raise AnchorMoved, "#{name}: no template served for #{spec.fetch("canonical")}; fetch `client.tools.list` first" if template.nil?
        raise AnchorMoved, "#{name}: the anchor moved; re-cut the entry: #{edit.fetch("anchor").lines.first.to_s.strip.inspect}" unless
          template.include?(edit.fetch("anchor"))

        template.sub(edit.fetch("anchor")) { edit.fetch("replacement") }
      end

      # A plain name is withheld without `nexus` when an active preset
      # supersedes its canonical; an alias is withheld without its preset;
      # every other name stays.
      def withheld?(name, styles, presets:)
        return superseded?(presets.canonical_of(name), styles, presets: presets) if presets.plain_name?(name)

        owner = presets.owner(name)
        !owner.nil? && !styles.include?(owner)
      end

      def superseded?(canonical, styles, presets:)
        !styles.include?(PLAIN_WORD) && styles.any? { |word| presets.preset(word).supersedes.include?(canonical) }
      end

      # The plain wire names a row's styles supersede — the words a hint of
      # that row must not backtick.
      def superseded_names(styles, presets:)
        presets.plain.select { |canonical, _name| superseded?(canonical, styles, presets: presets) }.values
      end

      def name_of(entry) = entry.dig("function", "name")

      def names_of(entries) = Array(entries).map { |entry| name_of(entry) }
    end
  end
end
