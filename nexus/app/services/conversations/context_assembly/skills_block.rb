module Conversations
  class ContextAssembly
    # THE SKILL CATALOG IN CONTEXT:
    # the memory block's twin. One line per skill the turn can load —
    # `- name: description` — under `Nexus::Skills::CATALOG_HEADER`, whose
    # first words the `skill` tool's description points at, so the two
    # texts name each other through one constant. Rendered ONCE PER TURN
    # into the sealed seed beside the memory block and FROZEN for the
    # loop: a source move mid-loop is the NEXT turn's fact, never a
    # running loop's prefix move — the memory block's cadence. Every
    # reference puts the catalog in context and none in a tool
    # description (the one that once did measured the cache cost and
    # moved it out); the pointer doctrine's own reason — a rewritten
    # description shifts the cached prefix — argues the same way.
    #
    # A PURE FUNCTION of (the two executor rows' `served_documents`, the
    # two rungs' `skills/` rows, the turn's memory principal) at the
    # instant of assembly: `AgentLoops::Skills::Catalog.for` is the one
    # merge — announced (the bound runner, then the agent address) >
    # workspace > user — and this class only lays its entries out. Two
    # Humans speaking in one room get two fronts (B's turn renders B's
    # `user/skills/*`, as the memory block renders B's notes): the memory
    # rule, accepted. Rendered ONLY when the turn's tool set declares
    # `nexus.skill.load` (a plain `skill` or an alias such as `Skill`,
    # found by canonical): a turn without the tool has no catalog and
    # costs zero queries; a `direct_reply` never carries one; under
    # `raw` there is no assembly and therefore no block. The override map
    # (`nexus.memory`) is ignored: a skill is the kernel's instruction
    # row, never the provider's.
    #
    # THE BOUND is `skill_catalog_bound` (16 KiB): lines are taken in
    # order until the next would cross it; the rest are named in ONE tail
    # line in the memory block's OMITTED form. One tail, never two: names
    # are ≤ 64 bytes, a rung holds ≤ 64 rows and an announcement is
    # envelope-bounded, so the names-only line is ≈ 12 KiB at the absolute
    # maximum — a second crossing no bounded source can reach. A
    # description is collapsed to one line (whitespace runs → one space)
    # and otherwise untouched: a truncated description is a lie about the
    # skill. Deterministic, so the same sources render the same bytes.
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
        # `tools` is the tool set the turn will declare — the caller's own
        # fact; `runner` the bound runner of a STANDALONE seed (a
        # conversation's is its own); `declaring_profile` the turn's, whose
        # address may announce documents; `principal` the User whose turn
        # this is, resolved to the `user/` rung exactly as memory resolves
        # it (`Source#memory_principal`).
        def call(conversation:, principal:, tools:, declaring_profile: nil, runner: nil,
                 budget: DEFAULT_BUDGET_BYTES)
          return Block.empty unless declares?(tools)

          source = Source.of(conversation)
          entries = AgentLoops::Skills::Catalog.for(
            runner: source.conversation&.bound_runner || runner,
            address: (TaskExecutor.address_for(declaring_profile) if declaring_profile),
            workspace_id: source.workspace_id,
            human: source.memory_principal(principal).controlling_human
          )
          return Block.empty if entries.empty?

          chosen, omitted = fit(entries, budget)
          Block.new(
            segments: [Segment.plain("user", render_text(chosen, omitted))],
            included: chosen.length, omitted: omitted.length
          )
        end

        # Whether the set names the load — by canonical, so an alias
        # counts; `wire` strips alias facts, so this runs on the STORED set.
        def declares?(tools)
          Array(tools).any? do |entry|
            Nexus::ToolDeclarations.canonical_of(entry) == AgentLoops::Skills::Catalog::CANONICAL
          end
        end

        def line(entry)
          format(LINE, entry.name, entry.description.to_s.gsub(/\s+/, " ").strip)
        end

        private

          # A PREFIX of the merge under one budget, stopping at the first
          # line that would cross it, so the block is always the highest-
          # precedence names rather than a size-selected subset nobody
          # could predict; the header is charged first.
          def fit(entries, budget)
            spent = HEADER.bytesize
            chosen = []
            omitted = []
            entries.each do |entry|
              rendered = line(entry)
              cost = rendered.bytesize + 1
              if omitted.empty? && spent + cost <= budget
                spent += cost
                chosen << rendered
              else
                omitted << entry.name
              end
            end
            [chosen, omitted]
          end

          def render_text(chosen, omitted)
            lines = [HEADER, *chosen]
            lines << "#{OMITTED} #{omitted.join(", ")}" if omitted.any?
            lines.join("\n")
          end
      end
    end
  end
end
