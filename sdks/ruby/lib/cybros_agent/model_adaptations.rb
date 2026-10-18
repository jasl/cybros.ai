require "yaml"

module CybrosAgent
  # THE MODEL-ADAPTATIONS PACK: a documented YAML data format whose rows are matched to a
  # model by PATTERN (`ModelPattern`), that an agent application applies on top of the
  # kernel's facts — the kernel tools' spellings for the models a row covers (`tool_style`,
  # `tool_descriptions`), a summarizer prompt, lead hints — every text is its
  # row's data, measured in the e2e harness before it lands.
  # Change history belongs in the promoting commit. The gem ships `presets.yml` (the alias
  # TABLES) and `rows/*.yml` (one file per row) under this directory; the format's
  # reference text is the README's "Model adaptations" section, the one home, written for
  # other languages too.
  #
  # Three things this module is NOT. It copies no kernel text: a preset's
  # description variant is a `recut` — ONE anchored edit rendered at
  # declare against the template `GET /tools` serves — and a moved anchor
  # is refused loudly (`AnchorMoved`), never a silent fallback. It
  # validates no alias NAME: the kernel is the one validator of an alias
  # entry at declaration (the harness renders every gem row through
  # `Nexus::ToolDeclarations.refusal`). It holds no candidates: candidate
  # text lives in the e2e harness (`e2e/evals/candidates/`) and enters a
  # row when its measurement there earns it.
  module ModelAdaptations
    FORMAT = 1
    DEFAULT_DIR = File.expand_path("model_adaptations", __dir__)
    DEFAULT_ROW = "default".freeze
    SOURCES = %w[gem local].freeze
    # The one style word that keeps every plain name beside the aliases.
    PLAIN_WORD = "nexus".freeze
    # A backticked identifier in a hint or a kernel text.
    BACKTICKED = /`([a-z_]+)`/

    # A malformed pack file, naming the file and the path inside it.
    class Invalid < Error
      attr_reader :file, :path

      def initialize(file, path, message)
        @file = file
        @path = path
        super("#{file}: #{path}: #{message}")
      end
    end

    # A `recut` whose anchor the served template no longer carries (or a
    # template the kernel did not serve): re-cut the entry by hand.
    class AnchorMoved < Error; end

    class << self
      # The gem's pack, plus LOCAL rows (`extra:` — row files or directories
      # of them, the operator's). A local row replaces a gem row of the
      # same id; one that replaces none answers before every gem row
      # (`Pack#for`).
      def load(dir = DEFAULT_DIR, extra: [])
        Loader.new(dir, extra: extra).pack
      end

      # A pack row is data the application reads and never edits.
      def freeze_deep(value)
        case value
        when Hash then value.to_h { |key, inner| [key.freeze, freeze_deep(inner)] }.freeze
        when Array then value.map { |inner| freeze_deep(inner) }.freeze
        else value.freeze
        end
      end
    end
  end
end

require_relative "model_adaptations/check"
require_relative "model_adaptations/alias_spec"
require_relative "model_adaptations/presets"
require_relative "model_adaptations/row"
require_relative "model_adaptations/styles"
require_relative "model_adaptations/pack"
require_relative "model_adaptations/presets_file"
require_relative "model_adaptations/row_file"
require_relative "model_adaptations/loader"
