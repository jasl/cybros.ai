module AgentLoops
  module Skills
    # THE MERGE: one pure derivation
    # of the skills a turn can load, from three sources and nothing else —
    # ANNOUNCED (the bound runner's `served_documents`, then the declaring
    # agent's address's: an executor contributes by announcement PRESENCE
    # alone, never a readiness query — eligibility is judged at the load,
    # where `tool_not_served` already refuses), then the WORKSPACE's
    # `skills/` rows, then the controlling Human's (the `user/` rung
    # of the loop's memory principal). A name clash resolves in that order
    # — announced > workspace > user, the references' agreement — and
    # inside the announced tier the runner precedes the address. Never a
    # pool: a document has one announcer. An entry is `(name,
    # description)` and carries no source: the skills block never renders
    # one, and the route (`Dispatch`) derives its own answer from the
    # announcements alone.
    #
    # The wire's PRESENCE rule rides here too: `declared` finds the
    # `skill` entry of a round's stored declaration BY CANONICAL FIRST — a
    # plain `skill` or an alias such as `Skill`, before `wire` strips the
    # alias facts — and derives nothing without it; with it, the entry is
    # omitted from the provider-bound set when `present?` says the merge is
    # empty (absent, not disabled: the stored declaration keeps it). No
    # entry's bytes are ever touched.
    module Catalog
      CANONICAL = "nexus.skill.load".freeze

      Entry = Data.define(:name, :description)

      module_function

      def for(runner:, address:, workspace_id:, human:)
        merged = {}
        [runner, address].each do |executor|
          announced(executor).each { |entry| merged[entry.name] ||= entry }
        end
        rows(MemoryDocument.skills.for_workspace(workspace_id)).each { |entry| merged[entry.name] ||= entry }
        rows(MemoryDocument.skills.for_user(human.id)).each { |entry| merged[entry.name] ||= entry } if human
        merged.values
      end

      # Whether the loop's merge holds anything: announcement presence on
      # the two executor rows the scheduler already holds, then — only when
      # both are empty — one `EXISTS` per kernel rung. No detoast, no
      # readiness query.
      def present?(agent_loop)
        return true if announced(agent_loop.bound_runner).any?
        return true if announced(Executors::Address.agent_address(agent_loop)).any?
        return true if MemoryDocument.skills.for_workspace(agent_loop.workspace_id).exists?

        human = agent_loop.memory_principal.controlling_human
        human.present? && MemoryDocument.skills.for_user(human.id).exists?
      end

      # The round's declared set as the wire sends it: untouched (zero
      # queries) when no entry names the canonical; the set WITHOUT that one
      # entry when the loop's merge is empty; the set untouched otherwise.
      def declared(entries, agent_loop)
        entries = Array(entries)
        entry = entries.find { |candidate| Nexus::ToolDeclarations.canonical_of(candidate) == CANONICAL }
        return entries if entry.nil? || present?(agent_loop)

        entries.reject { |candidate| candidate.equal?(entry) }
      end

      # An announcing executor's documents as entries — an inactive or
      # absent one contributes nothing (announcement presence).
      def announced(executor)
        return [] unless executor.present? && executor.active?

        Array(executor.served_documents).map do |document|
          Entry.new(name: document.fetch("name"), description: document.fetch("description"))
        end
      end

      # Whether `name` is one this executor announced — the ONE question the
      # route asks of a call's argument: membership in an announced list, an
      # address and never a meaning.
      def announces?(executor, name)
        announced(executor).any? { |entry| entry.name == name }
      end

      # One rung's rows, plucked by name: the description is a row fact, so
      # the catalog never detoasts a body to choose.
      def rows(scope)
        scope.order(:name).pluck(:name, :description).map do |name, description|
          Entry.new(name: Nexus::Skills.name_of(name), description: description.to_s)
        end
      end
    end
  end
end
