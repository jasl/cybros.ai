module Conversations
  class ContextAssembly
    # Render each loadable skill with its callable and source so equal names
    # on different Runners remain distinguishable. The declared tool routes
    # select Runner catalogs; kernel skill declarations merge Agent, workspace
    # and user sources. Catalog owns selection and this class only formats it.
    # The seed seals these bytes once for the Run, beside its memory block.
    #
    # The whole block, including the header and omission count, shares one
    # byte budget. Keep a prefix and whole descriptions so truncation cannot
    # change a skill's meaning or split a UTF-8 character.
    class SkillsBlock
      DEFAULT_BUDGET_BYTES = Nexus::SizeBounds.fetch(:skill_catalog_bound)
      HEADER = Nexus::Skills::CATALOG_HEADER
      OMITTED = "Not shown here (too many to include):".freeze
      LINE = "- %s: %s".freeze

      Block = Data.define(:segments, :included, :omitted) do
        def self.empty = new(segments: [], included: 0, omitted: 0)
        def empty? = segments.empty?
      end

      class << self
        # The turn's declarations select every source. Its principal supplies
        # the controlling Human's user catalog, as for memory assembly.
        def call(conversation:, principal:, tools:, declaring_profile: nil, environment: nil,
                 budget: DEFAULT_BUDGET_BYTES)
          tools = Nexus::ToolDeclarations.visible(tools)
          return Block.empty unless declares?(tools)

          source = Source.of(conversation)
          entries = if environment&.key?("skills")
            names = Nexus::ToolDeclarations.names(tools)
            environment.fetch("skills").filter_map do |entry|
              AgentRuns::Skills::Catalog::Entry.new(**entry.symbolize_keys) if names.include?(entry.fetch("callable"))
            end
          else
            AgentRuns::Skills::Catalog.for(
              tools: tools,
              address: (TaskExecutor.address_for(declaring_profile) if declaring_profile),
              workspace_id: source.workspace_id,
              human: source.memory_principal(principal).controlling_human
            )
          end
          return Block.empty if entries.empty?

          chosen, omitted = fit(entries, budget)
          Block.new(
            segments: [Segment.plain("user", render_text(chosen, omitted))],
            included: chosen.length, omitted: omitted
          )
        end

        # Whether the set names the load — by canonical, so an alias
        # counts; `wire` strips alias facts, so this runs on the STORED set.
        def declares?(tools)
          Array(tools).any? do |entry|
            AgentRuns::Skills::Catalog.skill?(entry)
          end
        end

        def line(entry)
          label = "#{entry.callable} / #{entry.name}"
          label += " [#{entry.executor_public_id}]" if entry.executor_public_id
          format(LINE, label, entry.description.to_s.gsub(/\s+/, " ").strip)
        end

        private

          # Reserve the tail after fitting, then remove only the last lines
          # until it fits too. Every removal increases the omission count;
          # the finite chosen prefix bounds this adjustment.
          def fit(entries, budget)
            spent = HEADER.bytesize
            chosen = []
            entries.each do |entry|
              rendered = line(entry)
              cost = rendered.bytesize + 1
              break if spent + cost > budget

              spent += cost
              chosen << rendered
            end
            omitted = entries.length - chosen.length
            while chosen.any? && omitted.positive? && spent + 1 + omitted_line(omitted).bytesize > budget
              spent -= chosen.pop.bytesize + 1
              omitted += 1
            end
            [chosen, omitted]
          end

          def render_text(chosen, omitted)
            lines = [HEADER, *chosen]
            lines << omitted_line(omitted) if omitted.positive?
            lines.join("\n")
          end

          def omitted_line(count) = "#{OMITTED} #{count} skills."
      end
    end
  end
end
