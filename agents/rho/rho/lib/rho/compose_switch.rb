module Rho
  # THE COMPOSE TIER: `compose` is the one kernel tool a weak model may not
  # drive, so it gets a switch of its own — per model, per conversation,
  # like a separate mode — and the switch lives on rho, because the AGENT
  # chooses what a turn carries; Nexus stays model-neutral.
  #
  # ONE RESOLVER, one ladder: the flag on `rho do`, else the `compose` word
  # when it is `on` or `off`, else — `auto` — the model's ADAPTATION ROW's
  # `compose` word (the SDK pack's recommendation, or a local row's; none under `adaptations: off`),
  # else on. Every rung names its source, which is what `rho do` prints
  # beside the tier. No gem row says `off` until a measurement earns
  # one: an operator who wants it writes a local row.
  #
  # The input's `tool_names` narrows the available tools: the profile declares the FULL set once — at boot and
  # every `rho env` — and a turn whose tier is off names every declared
  # tool but `compose` and its aliases on its input, beside its model. The kernel narrows
  # the declaration by those names at materialization, and the declaration
  # is the only gate, so "off" is absent from the bytes AND refused if
  # guessed. The switch only ever narrows: an operator who removed compose
  # from `kernel_tools` has switched it off for good, and `on` cannot bring
  # it back.
  module ComposeSwitch
    # The kernel tool's flat name — the spelling in the declaration and on
    # the input; `nexus.graph.compose` is the settings' canonical spelling.
    NAME = "compose".freeze
    WORDS = %w[on off].freeze
    MODES = (WORDS + %w[auto]).freeze

    Decision = Data.define(:on, :source) do
      def word = on ? "on" : "off"
    end

    module_function

    # `row` is the model's adaptation row (`Rho::Adaptations#for(model).row`),
    # nil under `adaptations: off` — the model is the row's subject, so the
    # ladder never reads a model id itself.
    def resolve(flag:, config:, row: nil)
      return Decision.new(on: flag == true, source: "flag") unless flag.nil?
      return Decision.new(on: config.compose == "on", source: "settings") unless config.compose == "auto"
      return Decision.new(on: row.compose?, source: "row #{row.id}") unless row.nil?

      Decision.new(on: true, source: "default")
    end

    # The subset the input names, by flat name: nil when the whole
    # declaration runs — the tier is on, or the declaration never carried
    # compose — else every declared name but compose and its aliases, in declaration order.
    def tool_names(declared, decision)
      return nil if decision.on

      names = declared.filter_map { |entry| entry.dig("function", "name") }
      withheld = declared.filter_map do |entry|
        name = entry.dig("function", "name")
        name if name == NAME || entry["canonical"] == "nexus.graph.compose"
      end
      return nil if withheld.empty?

      names - withheld
    end

    # The declared bytes the subset keeps: the same entries, fewer of them,
    # in the same order — what the kernel freezes onto round one, and what
    # a seed copying the turn's surface must carry.
    def narrow(declared, names)
      return declared if names.nil?

      declared.select { |entry| names.include?(entry.dig("function", "name")) }
    end
  end
end
