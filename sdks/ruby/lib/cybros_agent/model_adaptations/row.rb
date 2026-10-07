module CybrosAgent
  module ModelAdaptations
    # ONE ROW of the pack: the model PATTERNS it covers (`models`, each a
    # `ModelPattern` entry over the kernel's `ref` minus its provider
    # segment) and the row's spellings and texts, each field the row
    # author's data, honoured as written. `source` is where the file was
    # loaded from (`gem` | `local`), never written in it.
    Row = Data.define(:id, :models, :source, :tool_style, :tool_descriptions,
      :summarizer_prompt, :lead_hints) do
      def local? = source == "local"

      def gem? = source == "gem"

      # No entries, so it covers no reference: `default`, or a row only an
      # application's pin (rho's `adaptations: <id>`) reaches.
      def default? = models.empty?

      # How specifically the row covers a reference: its best entry's
      # rank (`ModelPattern.rank`), or nil when no entry matches.
      def specificity(reference) = ModelPattern.rank(models, reference)

      def hint_texts = lead_hints.map { |hint| hint.fetch("text") }
    end
  end
end
