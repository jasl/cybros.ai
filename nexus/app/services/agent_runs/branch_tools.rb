module AgentRuns
  # A branch inherits the round's tools, including delegation when declared.
  # The set is narrowed by name when the author names fewer.
  # A name the round never offered is the
  # refusal, so `task({tools})` answers with an actionable sentence. The by-name narrowing itself is
  # `Nexus::ToolDeclarations`' — the turn's `tool_names` narrows the
  # materialization seed through the same one.
  module BranchTools
    # The flat tools whose call key names the branch they made — wire
    # names, as the node's `tool_name` carries them under any alias.
    FLAT_VERBS = %w[delegate_task ask spawn wait tool_call].freeze
    # The flat tools whose tip a reader renders as the CALL's paired result: a
    # waited `task`'s branch, a waited `spawn`'s await. An ask's answer is read
    # material the await delivers, never a paired result.
    PAIRED_VERBS = %w[delegate_task spawn wait tool_call].freeze

    Narrowed = Data.define(:definitions, :refused)

    module_function

    def names(round) = Nexus::ToolDeclarations.names(round&.tool_definitions)

    # `wanted` nil inherits everything; a list keeps only those
    # names, and the first one the round cannot give is returned instead.
    def narrow(round, wanted)
      narrow_definitions(round&.tool_definitions, wanted)
    end

    def narrow_definitions(definitions, wanted)
      refused = wanted && Nexus::ToolDeclarations.undeclared(definitions, wanted)
      return Narrowed.new(definitions: nil, refused: refused) if refused

      inherited = Nexus::ToolDeclarations.narrow(definitions, wanted)
      Narrowed.new(definitions: rerender(Array(inherited)).presence, refused: nil)
    end

    # THE BRANCH'S OWN RENDER: the round's set spells every neighbour's
    # macro in the round's names (`spawn` says `Agent` under the claude
    # preset), and explicit narrowing may remove those spellings —
    # the subset's kernel bytes would read as `kernel_tool_redefined` at
    # compile. The same render the store holds, over the subset alone.
    def rerender(inherited)
      spellings = Nexus::ToolDeclarations::Render.spellings(inherited)
      plain = inherited.map do |definition|
        canonical = Nexus::ToolDeclarations.canonical_of(definition)
        next definition if canonical.nil? || Nexus::ToolDeclarations.alias?(definition) ||
          !Nexus::ToolRegistry.kernel_name?(canonical)

        Nexus::ToolDeclarations::Render.kernel_entry(canonical, spellings)
          .merge(definition.slice(*Nexus::ToolDeclarations::PRESENTATION_FIELDS))
      end
      Nexus::ToolDeclarations::Render.render(plain)
    end

    # The refusal a model reads, generated from what the round declared.
    def not_a_tool(verb, name, round)
      "#{verb}: #{name.inspect} is not one of your tools. You have: #{names(round).join(", ")}"
    end
  end
end
