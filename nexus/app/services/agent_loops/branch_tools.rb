module AgentLoops
  # The tools a branch inherits: the round's minus task and compose, so it
  # cannot recursively author graph branches; conversation spawn remains.
  # The set is narrowed by name when the author names
  # fewer. A name the round never offered, a withheld verb included, is the
  # refusal, so both `g.model({tools})` and `task({tools})` answer with the
  # same sentence. The by-name narrowing itself is
  # `Nexus::ToolDeclarations`' — the turn's `tool_names` narrows the
  # materialization seed through the same one.
  module BranchTools
    # Withheld by CANONICAL: a branch inherits neither the graph verbs nor any
    # alias of them — `Agent` is `task` spelled otherwise.
    WITHHELD = %w[nexus.graph.compose nexus.graph.task].freeze
    # The flat tools whose call key names the branch they made — wire
    # names, as the node's `tool_name` carries them under any alias.
    FLAT_VERBS = %w[task ask spawn wait].freeze
    # The flat tools whose tip a reader renders as the CALL's paired result: a
    # waited `task`'s branch, a waited `spawn`'s await. An ask's answer is read
    # material the await delivers, never a paired result.
    PAIRED_VERBS = %w[task spawn wait].freeze

    Narrowed = Data.define(:definitions, :refused)

    module_function

    def names(round) = Nexus::ToolDeclarations.names(round&.tool_definitions)

    # `wanted` nil inherits everything not withheld; a list keeps only those
    # names, and the first one the round cannot give is returned instead.
    def narrow(round, wanted)
      narrow_definitions(round&.tool_definitions, wanted)
    end

    def narrow_definitions(definitions, wanted)
      inherited = rerender(Array(definitions).reject do |definition|
        WITHHELD.include?(Nexus::ToolDeclarations.canonical_of(definition))
      end)
      # A withheld verb is undeclared for a branch: the inherited set never had it.
      refused = wanted && Nexus::ToolDeclarations.undeclared(inherited, wanted)
      return Narrowed.new(definitions: nil, refused: refused) if refused

      Narrowed.new(definitions: Nexus::ToolDeclarations.narrow(inherited, wanted).presence, refused: nil)
    end

    # THE BRANCH'S OWN RENDER: the round's set spells every neighbour's
    # macro in the round's names (`spawn` says `Agent` under the claude
    # preset), and with the graph verbs withheld those spellings are gone —
    # the subset's kernel bytes would read as `kernel_tool_redefined` at
    # compile. The same render the store holds, over the subset alone.
    def rerender(inherited)
      spellings = Nexus::ToolDeclarations::Render.spellings(inherited)
      plain = inherited.map do |definition|
        canonical = Nexus::ToolDeclarations.canonical_of(definition)
        next definition if canonical.nil? || Nexus::ToolDeclarations.alias?(definition) ||
          !Nexus::ToolRegistry.kernel_name?(canonical)

        Nexus::ToolDeclarations::Render.kernel_entry(canonical, spellings)
      end
      Nexus::ToolDeclarations::Render.render(plain)
    end

    # The refusal a model reads, generated from what the round declared.
    def not_a_tool(verb, name, round)
      "#{verb}: #{name.inspect} is not one of your tools. You have: #{names(round).join(", ")}"
    end
  end
end
