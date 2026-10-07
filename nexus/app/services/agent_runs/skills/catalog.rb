module AgentRuns
  module Skills
    # A frozen source-qualified catalog. Runner documents belong to their
    # explicitly declared callable; ordinary skills retain source precedence.
    module Catalog
      CANONICAL = "nexus.skill.load".freeze
      Entry = Data.define(:name, :description, :callable, :source, :executor_public_id)

      module_function

      def for(tools:, address:, workspace_id:, human:)
        Array(tools).flat_map do |declaration|
          next [] unless skill?(declaration)
          callable = Nexus::ToolDeclarations.name_of(declaration)
          route = declaration["route"]
          if route
            executor = TaskExecutor.where(executor_kind: :runner)
              .find_by(public_id: route.fetch("runner_executor_public_id"))
            announced(executor, callable: callable, source: "runner")
          else
            merged = {}
            announced(address, callable: callable, source: "agent_application").each { |entry| merged[entry.name] ||= entry }
            rows(MemoryDocument.skills.for_workspace(workspace_id), callable: callable, source: "workspace")
              .each { |entry| merged[entry.name] ||= entry }
            if human
              rows(MemoryDocument.skills.for_user(human.id), callable: callable, source: "user")
                .each { |entry| merged[entry.name] ||= entry }
            end
            merged.values
          end
        end
      end

      def skill?(entry)
        route = entry["route"]
        canonical = route ? Nexus::ToolRegistry.resolve(route["tool_name"]) : Nexus::ToolDeclarations.canonical_of(entry)
        canonical == CANONICAL
      end

      # A model's declaration is stable; document withdrawal is a load error.
      # Suppress an empty skill callable using the execution's frozen catalog.
      def declared(entries, agent_run, environment: nil)
        entries = Array(entries)
        return entries unless entries.any? { |entry| skill?(entry) }
        catalog = environment&.fetch("skills", nil)
        return entries if catalog.nil?

        kept = entries.reject do |entry|
          skill?(entry) && catalog.none? { |document| document["callable"] == Nexus::ToolDeclarations.name_of(entry) }
        end
        kept.length == entries.length ? entries : kept
      end

      def announced(executor, callable: nil, source: nil)
        return [] unless executor&.active?

        Array(executor.served_documents).map do |document|
          Entry.new(name: document.fetch("name"), description: document.fetch("description"),
            callable: callable, source: source, executor_public_id: executor.public_id)
        end
      end

      def loadable?(node, executor)
        return announces?(executor, node.tool_input["name"]) if node.authored_by == "author"

        documents = Executors::TaskOperations::Context.defaults(node).dig("environment", "skills")
        Array(documents).any? do |entry|
          entry["callable"] == (node.tool_alias || node.tool_name) && entry["name"] == node.tool_input["name"] &&
            entry["executor_public_id"] == executor.public_id
        end && announces?(executor, node.tool_input["name"])
      end

      def announces?(executor, name)
        announced(executor).any? { |entry| entry.name == name }
      end

      def rows(scope, callable:, source:)
        scope.order(:name).pluck(:name, :description).map do |name, description|
          Entry.new(name: Nexus::Skills.name_of(name), description: description.to_s,
            callable: callable, source: source, executor_public_id: nil)
        end
      end
    end
  end
end
