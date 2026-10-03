module CybrosAgent
  module ModelAdaptations
    # `presets.yml` read and validated: `format: 1`; `words` (unique);
    # `plain` (canonical → unique plain name); `presets` keyed by exactly
    # the words, each `{supersedes ⊆ plain's canonicals, aliases}` in the
    # alias grammar, every alias name spelled once across the tables.
    module PresetsFile
      KEYS = %w[format words plain presets].freeze
      PRESET_KEYS = %w[supersedes aliases].freeze

      module_function

      def read(path)
        check = Check.new(path)
        document = check.mapping(Yaml.load(path), "(document)", required: KEYS)
        check.format(document["format"])
        words = check.strings(document["words"], "words")
        plain = plain(check, document["plain"])
        presets = presets(check, document["presets"], words: words, plain: plain)
        Presets.new(words: ModelAdaptations.freeze_deep(words), plain: ModelAdaptations.freeze_deep(plain), presets: presets)
      end

      def plain(check, value)
        check.refuse("plain", "expected a mapping, got #{value.class}") unless value.is_a?(Hash)
        value.each { |canonical, name| check.string(canonical, "plain") && check.string(name, "plain.#{canonical}") }
        check.unique(value.values, "plain")
        value
      end

      def presets(check, value, words:, plain:)
        check.refuse("presets", "expected a mapping, got #{value.class}") unless value.is_a?(Hash)
        check.refuse("presets", "keys must be exactly the words: #{words.join(", ")}") unless value.keys.sort == words.sort
        presets = value.to_h { |word, spec| [word, preset(check, word, spec, plain: plain)] }
        check.unique(presets.values.flat_map { |preset| preset.aliases.map { |spec| spec.fetch("name") } }, "presets")
        presets.freeze
      end

      def preset(check, word, value, plain:)
        path = "presets.#{word}"
        spec = check.mapping(value, path, required: PRESET_KEYS)
        supersedes = check.subset(check.strings(spec["supersedes"], "#{path}.supersedes"), "#{path}.supersedes", plain.keys)
        aliases = check.array(spec["aliases"], "#{path}.aliases").each_with_index.map do |entry, index|
          AliasSpec.read(check, entry, "#{path}.aliases[#{index}]", plain: plain)
        end
        Preset.new(word: word, supersedes: ModelAdaptations.freeze_deep(supersedes), aliases: ModelAdaptations.freeze_deep(aliases))
      end
    end

    # The stdlib's YAML, in the safest mode: no tags, no aliases, UTF-8 by
    # name (this machine's default external is not).
    module Yaml
      module_function

      def load(path)
        YAML.safe_load(File.read(path, encoding: Encoding::UTF_8), permitted_classes: [], aliases: false, filename: path)
      rescue Psych::Exception => e
        raise Invalid.new(path, "(document)", e.message)
      end
    end
  end
end
