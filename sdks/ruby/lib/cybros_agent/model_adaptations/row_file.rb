module CybrosAgent
  module ModelAdaptations
    # ONE `rows/<id>.yml` read and validated. Required: `format: 1`, `row`
    # (equal to the file's basename), `models`, `tool_style`, `compose`;
    # the texts default to none (`tool_descriptions: []`,
    # `summarizer_prompt: null`, `lead_hints: []`) and are
    # honoured as written on a gem row and a local row alike. The rules:
    # every `models` entry is a model pattern (`ModelPattern.refusal`
    # names the rule a stranger breaks — whether one matches a catalog
    # model is the harness's pin, the loader has no catalog);
    # `tool_style` words are the tables'; `compose` is `on | off` (YAML's
    # own `on`/`off` booleans read the same); a hint is spelled in the
    # row's own style — a backticked plain name the row's styles supersede
    # is refused, because the model never sees that word.
    module RowFile
      KEYS = %w[format row models tool_style tool_descriptions summarizer_prompt lead_hints compose].freeze
      REQUIRED = %w[format row models tool_style compose].freeze
      HINT_KEYS = %w[id text].freeze

      module_function

      def read(path, presets:, source:)
        check = Check.new(path)
        document = check.mapping(Yaml.load(path), "(document)", required: REQUIRED, optional: KEYS - REQUIRED)
        check.format(document["format"])
        id = check.string(document["row"], "row")
        check.refuse("row", "#{id.inspect} is not the file's name #{File.basename(path, ".yml").inspect}") unless
          id == File.basename(path, ".yml")
        fields = {
          id: id, models: models(check, document["models"]), source: check.one_of(source, "(source)", SOURCES),
          tool_style: check.subset(check.strings(document["tool_style"], "tool_style"), "tool_style", presets.words),
          tool_descriptions: descriptions(check, document.fetch("tool_descriptions", []), presets: presets),
          summarizer_prompt: check.optional_string(document["summarizer_prompt"], "summarizer_prompt"),
          lead_hints: hints(check, document.fetch("lead_hints", [])),
          compose: compose(check, document["compose"]),
        }
        row = Row.new(**ModelAdaptations.freeze_deep(fields)).freeze
        rules(check, row, presets: presets)
        row
      end

      def models(check, value)
        check.strings(value, "models").each_with_index do |entry, index|
          reason = ModelPattern.refusal(entry)
          check.refuse("models[#{index}]", reason) unless reason.nil?
        end
      end

      def descriptions(check, value, presets:)
        entries = check.array(value, "tool_descriptions").each_with_index.map do |entry, index|
          AliasSpec.read(check, entry, "tool_descriptions[#{index}]", plain: presets.plain)
        end
        check.unique(entries.map { |entry| entry.fetch("name") }, "tool_descriptions")
        entries
      end

      def hints(check, value)
        hints = check.array(value, "lead_hints").each_with_index.map do |hint, index|
          path = "lead_hints[#{index}]"
          check.mapping(hint, path, required: HINT_KEYS)
          HINT_KEYS.each { |key| check.string(hint[key], "#{path}.#{key}") }
          hint
        end
        check.unique(hints.map { |hint| hint.fetch("id") }, "lead_hints")
        hints
      end

      # YAML 1.1 reads a bare `on`/`off` as a boolean; both spellings mean
      # the same two words.
      def compose(check, value)
        word = { true => "on", false => "off" }.fetch(value, value)
        check.one_of(word, "compose", COMPOSE_WORDS)
      end

      # The one rule that reads the whole row: the own-style rule for hints.
      def rules(check, row, presets:)
        superseded = Styles.superseded_names(row.tool_style, presets: presets)
        row.lead_hints.each_with_index do |hint, index|
          quoted = hint.fetch("text").scan(BACKTICKED).flatten & superseded
          check.refuse("lead_hints[#{index}].text", "names `#{quoted.first}`, a plain word the row's styles supersede") unless
            quoted.empty?
        end
      end
    end
  end
end
