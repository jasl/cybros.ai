module Runs
  module Skills
    # A frozen source-qualified catalog. Runner documents belong to their
    # explicitly declared callable; ordinary skills retain source precedence.
    module Catalog
      CANONICAL = "nexus.skill.load".freeze
      Entry = Data.define(:name, :description, :callable, :source, :executor_public_id, :collection_public_id, :document_public_id) do
        def initialize(collection_public_id: nil, document_public_id: nil, **) = super
      end

      module_function

      # Source precedence for a non-Runner callable, first name wins: the
      # Agent's announced documents, the answering agent's own
      # `agent/skills/` rows, the room's `workspace/skills/`, the selected
      # `speaker/skills/`, then an explicit Human `user/skills/` binding.
      def for(tools:, address:, context:)
        Array(tools).flat_map do |declaration|
          next [] unless skill?(declaration)
          callable = Nexus::ToolDeclarations.name_of(declaration)
          route = declaration["route"]
          if route
            executor = Executor.providing(:runner)
              .find_by(public_id: route.fetch("runner_executor_public_id"))
            announced(executor, callable: callable, source: "runner")
          else
            merged = {}
            announced(address, callable: callable, source: "agent").each { |entry| merged[entry.name] ||= entry }
            context.bindings.each_with_index.sort_by { |binding, index| [%i[agent workspace speaker user conversation].index(binding.scope), index] }.each do |binding, _index|
              next if binding.scope == :conversation

              rows(binding.collection, callable: callable, source: binding.name)
                .each { |entry| merged[entry.name] ||= entry }
            end
            merged.values
          end
        end
      end

      def skill?(entry)
        route = entry["route"]
        return false if route && route.fetch("kind") == "mcp"

        canonical = route ? Nexus::ToolRegistry.resolve(route["tool_name"]) : Nexus::ToolDeclarations.canonical_of(entry)
        canonical == CANONICAL
      end

      # A model's declaration is stable; document withdrawal is a load error.
      # Suppress an empty skill callable using the execution's frozen catalog.
      def declared(entries, run, environment: nil)
        entries = Array(entries)
        return entries unless entries.any? { |entry| skill?(entry) }
        catalog = environment&.fetch("skills", nil)
        return entries if catalog.nil?

        kept = entries.reject do |entry|
          skill?(entry) && catalog.none? { |document| document["callable"] == Nexus::ToolDeclarations.name_of(entry) }
        end
        kept.length == entries.length ? entries : kept
      end

      def announced(executor, callable: nil, source:)
        return [] unless executor&.active?

        executor.documents_for(source).map do |document|
          Entry.new(name: document.fetch("name"), description: document.fetch("description"),
            callable: callable, source: source, executor_public_id: executor.public_id)
        end
      end

      def loadable?(node, executor)
        return announces?(executor, node.tool_input["name"], role: :runner) if node.authored_by == "author"

        documents = Executors::TaskOperations::Context.defaults(node).dig("environment", "skills")
        Array(documents).any? do |entry|
          entry["callable"] == (node.tool_alias || node.tool_name) && entry["name"] == node.tool_input["name"] &&
            entry["executor_public_id"] == executor.public_id
        end && announces?(executor, node.tool_input["name"], role: :runner)
      end

      def announces?(executor, name, role:)
        announced(executor, source: role).any? { |entry| entry.name == name }
      end

      def rows(collection, callable:, source:)
        collection.memory_documents.skills.order(:name).pluck(:name, :description, :public_id).map do |name, description, public_id|
          Entry.new(name: Nexus::Skills.name_of(name), description: description.to_s,
            callable: callable, source: source, executor_public_id: nil,
            collection_public_id: collection.public_id, document_public_id: public_id)
        end
      end
    end
  end
end
