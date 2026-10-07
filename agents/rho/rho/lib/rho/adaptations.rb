require "cybros_agent"
require "digest"

module Rho
  # RHO'S POLICY OVER THE SDK'S MODEL-ADAPTATIONS PACK: the
  # pack is the SDK's — the alias TABLES, the rows matched to a model by
  # pattern, each text measured before it lands — and rho decides ONE thing
  # on top of it with ONE knob, `adaptations: auto | off | <row>`, plus
  # LOCAL rows under `adaptations_dir` (whole rows the operator writes for
  # a model no gem row covers, or to replace the gem's row; a local row
  # that replaces none answers before every gem row). A local row owns
  # the per-model tool spellings and texts.
  #
  # THE UNIVERSE IS THE BOOT ROW. The profile declares
  # once at the workspace-adopted edge, and the declaration is the front of
  # every cached prefix, so a row's SPELLINGS are a boot-time choice: the
  # pinned row, else under `auto` the row of `default_model` (none →
  # `default`), else under `off` the kernel's plain declaration. The alias
  # intentions stay the same across turns. A `--model X` whose row differs runs under
  # the boot row's spellings and says so; X's row still decides the
  # per-turn `lead_hints`.
  class Adaptations
    OFF = "off".freeze
    AUTO = "auto".freeze
    MODES = [AUTO, OFF].freeze
    # A row id is a file's basename: the pack refuses any other spelling.
    ROW_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    Pack = CybrosAgent::ModelAdaptations

    # ONE RESOLUTION: the row, and where it came from as the terminal
    # prints it — `gem`, `local <path>`, or `off` (the knob's word: the
    # kernel's plain declaration, which is the `default` row's set).
    Choice = Data.define(:row, :off, :path) do
      def off? = off

      def id = off? ? OFF : row.id

      # `gem` | `local` | `off`: the word beside the row on every line.
      def source = off? ? OFF : row.source

      # `mock (local)` on `rho do` and `rho status`; `off` under the knob.
      def label = off? ? OFF : "#{row.id} (#{row.source})"

      # `mock (local /home/adaptations/mock.yml)` on `rho adaptations`.
      def long_label = off? || path.nil? ? label : "#{row.id} (#{row.source} #{path})"

      def hint_texts = off? ? [] : row.hint_texts
    end

    class << self
      # The pack the settings name — the gem's rows, then every `*.yml`
      # under `adaptations_dir` as LOCAL rows — and the knob, checked
      # against it: a pinned row must exist. A malformed local row refuses
      # the boot by its file and path, never a silent skip.
      def load(config, home:)
        dir = config.adaptations_dir || home.adaptations_path
        pack = Pack.load(extra: (File.directory?(dir) ? [dir] : []))
        new(pack: pack, knob: config.adaptations, dir: dir, default_model: config.default_model,
          compaction_model: config.plugin_configuration("rho.compaction")["model"])
      rescue Pack::Invalid => error
        raise ConfigurationError, "adaptations: #{error.message}"
      end

      # THE LINE the terminal prints from a daemon's facts (`rho do`, `rho
      # status`) or the CLI's own: `mock (local)`, `glm-5.3 (gem)`, `off`,
      # and `kimi-k3 (gem; boot row glm-5.3)` when the turn's row is not
      # the boot's.
      def describe(facts)
        facts = facts.to_h.transform_keys(&:to_s)
        row = facts["row"].to_s
        return OFF if row == OFF || row.empty?

        source = [facts["source"], ("boot row #{facts["boot_row"]}" if facts["boot_row"])].compact.join("; ")
        "#{row} (#{source})"
      end

      # THE KNOB'S GRAMMAR, for `Config`: `auto`, `off`, or a row id; the
      # id's existence is the pack's to judge at load.
      def knob(value)
        word = value.to_s.strip
        return word if MODES.include?(word)
        return word if ROW_ID.match?(word)

        raise ConfigurationError, "adaptations must be auto, off or a row id, got #{value.inspect}"
      end
    end

    attr_reader :pack, :knob, :dir

    def initialize(pack:, knob:, dir:, default_model: nil, compaction_model: nil)
      @pack = pack
      @knob = knob
      @dir = dir
      @default_model = default_model
      @compaction_model = compaction_model
      @pinned = pinned_row
      freeze
    end

    def off? = knob == OFF

    def auto? = knob == AUTO

    def pinned? = !@pinned.nil?

    # THE ROW FOR A MODEL: the pinned row, else under `auto` the row the
    # reference resolves to (`Pack#for`: the lane segment stripped, the
    # most specific entry answering), else `default`; under `off` the
    # default row marked off.
    def for(model)
      return Choice.new(row: pack.default, off: true, path: nil) if off?

      row = @pinned || (model.nil? ? pack.default : pack.for(model))
      Choice.new(row: row, off: false, path: path_of(row))
    end

    # THE BOOT ROW — the universe the profile declares: the pinned row,
    # else the row of `default_model`.
    def boot = self.for(@default_model)

    # THE SLOT ROW — whose `summarizer_prompt` the profile's `summarizer`
    # slot carries: the pinned row, else `compaction.model || default_model`.
    # Without an explicit summary model the kernel inherits each turn's
    # model, while this profile-wide text stays on the boot default's row.
    def summarizer = self.for(@compaction_model || @default_model)

    # `--model X` under `auto` may resolve a row other than the boot's:
    # its spellings are the boot's and its hints are its own.
    def boot_differs?(model) = !off? && !pinned? && self.for(model).row.id != boot.row.id

    # The boot row chooses canonical exports and compact aliases. The served
    # templates anchor recuts; Nexus remains the only schema assembler.
    def kernel_configuration(names:, templates: {}, wire_names: {})
      styles = CybrosAgent::ModelAdaptations::Styles
      row = boot.row
      presets = pack.presets
      aliases = styles.alias_specs(row, presets: presets).filter_map do |spec|
        next unless names.include?(spec.fetch("canonical"))

        entry = styles.entry(spec, templates: templates)
        spec.fetch("canonical") == "nexus.skill.load" ? entry.merge("defer_loading" => true) : entry
      end
      names = names.reject { |name| styles.superseded?(name, row.tool_style, presets: presets) }
      if names.include?("nexus.skill.load")
        aliases << CybrosAgent::Api::ToolCatalog.new(dispatch: nil).alias(
          name: wire_names.fetch("nexus.skill.load"), canonical: "nexus.skill.load", defer_loading: true)
      end
      { kernel_tools: names, kernel_aliases: aliases }
    end

    # The facts the daemon's status and a `rho do` answer carry.
    def facts(model = nil)
      choice = self.for(model || @default_model)
      facts = { row: choice.id, source: choice.source }
      facts[:boot_row] = boot.id if model && boot_differs?(model)
      facts
    end

    # The path a local row was loaded from, for `rho adaptations`.
    def path_of(row)
      return nil unless row.local?

      File.join(dir, "#{row.id}.yml")
    end

    private

      def pinned_row
        return nil if MODES.include?(knob)

        pack.row(knob) || raise(ConfigurationError,
          "adaptations names no row #{knob.inspect}; the rows: #{pack.ids.join(", ")} (local rows live under #{dir})")
      end
  end
end
