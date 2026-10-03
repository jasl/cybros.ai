module CybrosAgent
  module ModelAdaptations
    # One preset word: which plain canonicals it supersedes without
    # `nexus`, and its alias entries in declaration order.
    Preset = Data.define(:word, :supersedes, :aliases)

    # THE ALIAS TABLES (`presets.yml`): the words in declaration order, the
    # canonical → plain wire name map, and one `Preset` per word. `owners`
    # is derived once — which preset owns each alias spelling, so a set
    # withholds a spelling whose preset a row does not name.
    Presets = Data.define(:words, :plain, :presets, :owners) do
      def initialize(words:, plain:, presets:)
        owners = presets.values.flat_map { |preset| preset.aliases.map { |spec| [spec.fetch("name"), preset.word] } }.to_h
        super(words: words, plain: plain, presets: presets, owners: ModelAdaptations.freeze_deep(owners))
      end

      def preset(word) = presets.fetch(word)

      # The active presets' aliases in `words` order, never the list's.
      def aliases_for(styles)
        words.select { |word| styles.include?(word) }.flat_map { |word| preset(word).aliases }
      end

      # The plain wire name of a canonical the tables spell.
      def plain_name(canonical) = plain.fetch(canonical)

      def plain_name?(name) = plain.value?(name)

      def canonical_of(name) = plain.key(name)

      # The preset word that owns an alias spelling, nil for any other name.
      def owner(name) = owners[name]
    end
  end
end
