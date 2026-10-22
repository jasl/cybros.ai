require "digest"

module Rho
  module PresetExecution
    # One live directory feeds both the settings picker and execution compiler.
    # Authored exclusions use connection identity, independently of callable names.
    module Mcp
      module_function

      def directory(client:, candidates:, agent_public_id:, agent_tools:)
        connections = []
        after = nil
        loop do
          page = client.mcp_connections.list(after: after, limit: 100)
          connections.concat(page.items.map do |connection|
            ref = { "source" => "nexus", "connection_public_id" => connection.public_id }
            { "ref" => ref, "name" => connection.name, "account_label" => connection.account_label,
              "available" => connection.available, "tools" => connection.tools.map do |tool|
                tool.merge("callable_name" => callable_name(ref, tool.fetch("name")))
              end }
          end)
          after = page.next_after
          break unless after
        end
        connections.concat(executor_connections(agent_public_id, agent_tools, runner: false))
        candidates.each do |executor|
          connections.concat(executor_connections(executor.public_id, RunDeclaration.served_entries(executor.tools_for(:runner)),
            runner: true, label: executor.display_name))
        end
        connections
      end

      def executor_connections(public_id, tools, runner:, label: nil)
        tools.select { |tool| tool["mcp"] && tool["description"] && tool["input_schema"] }
          .group_by { |tool| tool.fetch("mcp").fetch("server_key") }.map do |server, offered|
          ref = { "source" => "executor", "executor_public_id" => public_id, "server_key" => server }
          { "ref" => ref, "name" => server, "account_label" => label, "available" => true,
            "tools" => offered.map do |tool|
              remote = tool.fetch("mcp").fetch("tool_name")
              name = runner ? callable_name(ref, remote) : tool.fetch("name")
              definition = CybrosAgent::Api::ToolLowering.function_entry(tool).merge("defer_loading" => true)
              definition["function"] = definition.fetch("function").merge("name" => name)
              if runner
                definition["route"] = { "kind" => "runner", "runner_executor_public_id" => public_id, "tool_name" => tool.fetch("name") }
              end
              { "name" => remote, "description" => tool.fetch("description"), "input_schema" => tool.fetch("input_schema"),
                "callable_name" => name, "definition" => definition }
            end }
        end
      end

      def callable_name(ref, tool_name)
        identity = ref.sort.flatten.join("\0") + "\0#{tool_name}"
        label = "#{ref["server_key"] || "nexus"}__#{tool_name}".gsub(/[^a-zA-Z0-9_-]/, "_")[0, 45]
        "mcp__#{label}__#{Digest::SHA256.hexdigest(identity)[0, 12]}"
      end

      def public_directory(directory)
        directory.map do |connection|
          connection.merge("tools" => connection.fetch("tools").map { |tool| tool.except("definition") })
        end
      end

      def selected(directory, selection)
        directory.flat_map do |connection|
          ref = connection.fetch("ref")
          next [] unless connection.fetch("available")
          next [] if selection.fetch("disabled_connections").include?(ref)

          connection.fetch("tools").filter_map do |tool|
            next if selection.fetch("disabled_tools").include?(ref.merge("tool_name" => tool.fetch("name")))

            [ref, tool]
          end
        end
      end

      def names(directory, selection)
        selected(directory, selection).map { |_ref, tool| tool.fetch("callable_name") }
      end

      # A callable spelling alone does not establish provenance. Keep ordinary
      # collisions intact so Nexus can reject them through its existing grammar.
      def without_imports(entries, directory)
        imported = directory.select { |connection| connection.fetch("ref").fetch("source") == "executor" }
          .flat_map { |connection| connection.fetch("tools").map { |tool| tool.fetch("definition").except("defer_loading") } }
        entries.reject { |entry| imported.include?(entry.except("defer_loading")) }
      end

      def apply(declaration, directory, selection)
        definitions = without_imports(declaration.fetch(:tool_definitions), directory)
        imports = []
        selected_tools = selected(directory, selection)
        selected_tools.each do |ref, tool|
          if ref.fetch("source") == "nexus"
            imports << { "connection_public_id" => ref.fetch("connection_public_id"), "tool_name" => tool.fetch("name"),
              "name" => tool.fetch("callable_name") }
          else
            definitions << tool.fetch("definition")
          end
        end
        declaration.merge(tool_definitions: definitions, mcp_tools: imports)
      end

      # Nexus rule globs use only * and ?; all other characters are literal.
      # This compiler narrows selectors, leaving argument matching to Nexus.
      def matching_names(pattern, names)
        patterns = pattern.split("|").map do |word|
          Regexp.new("\\A#{Regexp.escape(word).gsub('\\*', ".*").gsub('\\?', ".")}\\z", Regexp::MULTILINE)
        end
        names.select { |name| patterns.any? { |expression| expression.match?(name) } }
      end
    end
  end
end
