module Nexus
  module ToolRegistry
    # The skill family's one entry (`nexus.skill.load`, routed per call by
    # its argument's announcer). ONE SLICE of the live table: the bytes of
    # each entry are the kernel's model-facing text and are pinned by
    # `contracts:generate` (tools.json); `LIVE` is the four slices in
    # order. `Tool` and the effect constants are the registry's own.
    module Skill
      TOOLS = [
        # THE SKILL LOAD. The catalog the text points at is the turn's `skills`
        # assembly block — NEVER this description: a list embedded here would move the
        # cached prefix's front on every source move (Claude Code measured 10.2 % of
        # fleet cache_creation from exactly that and moved its list out). The quoted
        # title is `Nexus::Skills::CATALOG_TITLE`, so the block and the tool name each
        # other through one constant. ROUTED BY SOURCE (the registry's
        # `ROUTED_BY_SOURCE`): a `name` the bound runner or the agent address
        # announced under `documents` is dispatched to that announcer as this same
        # row; every other name runs in-process, where the kernel's own `skills/` rows
        # answer it or the result is the error `skill_unknown`. Never backtick `skill`
        # in any kernel text: rho-runner announces a tool of that name (the cross-tree
        # pin).
        Tool.new(
          canonical: "nexus.skill.load",
          name: "skill",
          template: <<~TEXT.strip,
            Load the full instructions of one skill from the "#{Nexus::Skills::CATALOG_TITLE}" list
            in this conversation. When the person names a skill, or the task clearly
            matches a skill's description, call {{skill}} with the exact name from that
            list BEFORE acting on the task, then follow the loaded instructions. The list
            carries summaries only: never follow, quote or guess a skill's instructions
            before loading it, and never name a skill you have not loaded. Load every
            skill that applies; do not load one twice.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "name" => { "type" => "string",
                          "description" => "The exact skill name from the \"#{Nexus::Skills::CATALOG_TITLE}\" list." },
            },
            "required" => ["name"],
          },
          effect_profile: READ_ONLY_CLOSED,
          executor: "AgentLoops::Memory::Run", job: "AgentLoops::MemoryJob",
        ),
      ].freeze
    end
  end
end
