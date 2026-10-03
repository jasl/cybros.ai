require "json"
require "cybros_agent"
require_relative "../../../nexus/lib/nexus/tool_registry"
require_relative "../../../nexus/lib/nexus/tool_declarations"
require_relative "../../../nexus/lib/nexus/tool_declarations/render"
require_relative "../adaptation_rows"
require_relative "tools"

module E2E
  module ComposeBench
    # The style axis changes the declared spellings beside `compose`: `nexus` uses plain kernel
    # names, `claude` uses `Agent` and `AskUserQuestion`, and `codex` retains plain `task` here
    # because its `spawn_agent` and `send_message` aliases name conversation tools this matrix does
    # not declare. Both benches build rows through `AdaptationRows.style_row` and render with
    # `kernel_entries_under`. The compose text uses the same declaration set, including plain-name
    # preference when two presets coexist. This isolates whether familiar tool names draw a model
    # away from compose.
    module Styles
      # The two canonicals a preset re-spells, as the catalog's plain bytes:
      # what `Styles.apply` keeps under `nexus` and aliases otherwise.
      PLAIN = %w[nexus.graph.task nexus.human.ask].freeze

      Style = Data.define(:id, :words, :kernel_entries) do
        # The string-keyed set the manifest records and the replay declares
        # beside compose: the harness's five tools, then the style's.
        def declared = Tools.function_definitions + kernel_entries

        def names = declared.map { |entry| entry.dig("function", "name") }

        # The set's spelling of every kernel wire name (the kernel's
        # preference rule), for the row's compose text.
        def spellings = Nexus::ToolDeclarations::Render.spellings(kernel_entries)

        # The row's compose definition rendered under this set.
        def definition_for(row) = row.definition(spellings)

        # The provider-bound entries, symbol-keyed: the alias facts stripped
        # exactly as the kernel strips them at its one provider-bound site.
        def wire = Nexus::ToolDeclarations.wire(kernel_entries).map(&:deep_symbolize_keys)
      end

      module_function

      # The preset words the SDK pack's tables know.
      def words = AdaptationRows.pack.presets.words

      def ids(env = ENV) = env.fetch("E2E_BENCH_STYLES", "nexus").split(",").map(&:strip).reject(&:empty?)

      def all(env = ENV) = ids(env).map { |id| find(id) }

      # One style by id: its words are preset names joined by `+`, each one
      # the tables know (anything else is an error, never a silent
      # baseline); its kernel entries are the catalog's plain `task`/`ask`
      # under the style's harness row, rendered by the kernel.
      def find(id)
        style_words = AdaptationRows.words(id)
        row = AdaptationRows.style_row(id, style_words)
        Style.new(id: id, words: style_words, kernel_entries: AdaptationRows.kernel_entries_under(row, plain))
      end

      def plain = PLAIN.map { |canonical| Nexus::ToolRegistry.function_definition(canonical) }
    end
  end
end
