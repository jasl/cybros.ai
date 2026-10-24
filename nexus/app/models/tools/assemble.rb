module Tools
  # One acceptance-time composition for Agents and authored model work.
  # Candidates describe where new work may start; only the selected Runner
  # contributes automatic tools. Explicit routes remain independent declarations.
  class Assemble
    def self.call(...) = new(...).call

    def self.for_agent(agent:, declaration: nil, runner: nil, tool_names: nil)
      return Result.new if agent.nil?

      configuration = declaration || agent
      call(principal: agent, tool_definitions: configuration.tool_definitions,
        kernel_tools: configuration.kernel_tools, runner_executor_public_ids: configuration.runner_executor_public_ids,
        runner_tool_names: configuration.runner_tool_names, mcp_tools: configuration.mcp_tools, runner: runner, tool_names: tool_names)
    end

    def initialize(principal:, tool_definitions:, kernel_tools:, runner_executor_public_ids:,
                   runner_tool_names:, mcp_tools: nil, runner: nil, tool_names: nil)
      @principal = principal
      @explicit = Array(tool_definitions).map do |entry|
        route = entry["route"]
        route ? entry.merge("route" => Nexus::ToolRoute.normalize(route)) : entry
      end
      @mcp_tools = Array(mcp_tools).map { |entry| entry.merge("connection_public_id" => entry.fetch("connection_public_id").downcase) }
      @kernel_tools = Array(kernel_tools)
      # PostgreSQL UUID attributes read back lowercase, independently of the
      # caller's spelling. Compare the declared identities in that same form.
      @candidate_ids = Array(runner_executor_public_ids).map(&:downcase)
      @runner_tool_names = runner_tool_names
      @runner_id = runner&.public_id
      @tool_names = tool_names
    end

    def call
      if @runner_id && !@candidate_ids.include?(@runner_id)
        return Result.new(refusal: :runner_not_declared)
      end

      load_routes
      return Result.new(refusal: :runner_not_eligible) if @runner_id && !eligible?(@runner_id)

      refusal = mcp_import_refusal
      return Result.new(refusal: refusal) if refusal

      selected = @executors[@runner_id]
      imported = mcp_definitions + runner_definitions(selected)

      # The stored declarations already passed their own grammar. Adding plain
      # tools can change an alias macro's preferred spelling, so render the final
      # set with the existing renderer before applying the shared grammar again.
      definitions = Nexus::ToolDeclarations::Render.render(base_definitions + imported)
      refusal = Nexus::ToolDeclarations.refusal(definitions)
      return Result.new(refusal: refusal.to_sym) if refusal
      if @tool_names && Nexus::ToolDeclarations.undeclared(definitions, @tool_names)
        return Result.new(refusal: :tool_not_declared)
      end

      definitions = Nexus::ToolDeclarations.canonical(definitions)
      if @tool_names
        definitions = Nexus::ToolDeclarations::Render.render(Nexus::ToolDeclarations.narrow(definitions, @tool_names))
      end
      unless Nexus::SizeBounds.json_within?(:tool_definitions_bound, definitions)
        return Result.new(refusal: Nexus::SizeBounds::REJECTION)
      end
      refusal = route_refusal(definitions)
      if refusal
        Result.new(refusal: refusal)
      else
        Result.new(definitions: definitions, environment: environment(definitions))
      end
    end

    private

      def load_routes
        routes = @explicit.filter_map { |entry| entry["route"] }
        runner_ids = routes.filter_map { |route| route["runner_executor_public_id"] }
        connection_ids = (@mcp_tools + routes).filter_map { |entry| entry["connection_public_id"] }
        @routes = Routes.new(principal: @principal,
          runner_ids: (@candidate_ids + runner_ids + [@runner_id]).compact.uniq,
          connection_ids: connection_ids.uniq)
        @executors = @routes.executors
        @connections = @routes.connections
      end

      def eligible?(public_id) = @routes.runner_eligible?(public_id)

      def base_definitions
        @base_definitions ||= begin
          explicit_names = Nexus::ToolDeclarations.names(@explicit)
          plain = @kernel_tools.map { |canonical| Nexus::ToolRegistry.function_definition(canonical) }
            .reject { |entry| explicit_names.include?(Nexus::ToolDeclarations.name_of(entry)) }
          @explicit + plain
        end
      end

      def runner_definitions(runner)
        return [] if runner.nil?

        # MCP selections use explicit routes, so an automatic Runner import
        # cannot restore a connection the application or parent disabled.
        offered = runner.tools_for(:runner).select { |entry| entry["description"] && entry["input_schema"] && !entry["mcp"] }
        if @runner_tool_names
          offered = offered.select { |entry| @runner_tool_names.include?(entry.fetch("name")) }
        end
        explicit_names = Nexus::ToolDeclarations.names(base_definitions + mcp_definitions)
        offered.map do |entry|
          served_name = entry.fetch("name")
          name = if explicit_names.include?(served_name) || Nexus::ToolRegistry.kernel_name?(served_name)
            qualified_name(runner.public_id, served_name)
          else
            served_name
          end
          {
            "type" => "function",
            "function" => { "name" => name, "description" => entry.fetch("description"),
              "parameters" => entry.fetch("input_schema") },
            "route" => { "kind" => "runner", "runner_executor_public_id" => runner.public_id,
              "tool_name" => served_name },
            "defer_loading" => true,
          }
        end
      end

      # Keep readable names bounded for model providers. Both full values feed
      # the digest, so long names sharing a prefix retain distinct callables.
      def qualified_name(public_id, name)
        "#{name[0, 49]}__#{Digest::SHA256.hexdigest("#{public_id}\0#{name}")[0, 12]}"
      end

      def mcp_import_refusal
        @mcp_tools.each do |entry|
          refusal = @routes.mcp_refusal(entry)
          return refusal if refusal
        end
        nil
      end

      def mcp_definitions
        @mcp_definitions ||= @mcp_tools.map do |selection|
          connection = @connections.fetch(selection.fetch("connection_public_id"))
          tool = connection.tools_catalog.find { |entry| entry.fetch("name") == selection.fetch("tool_name") }
          {
            "type" => "function",
            "function" => { "name" => selection.fetch("name"), "description" => tool.fetch("description"),
              "parameters" => tool.fetch("input_schema") },
            "route" => { "kind" => "mcp", "connection_public_id" => connection.public_id,
              "tool_name" => selection.fetch("tool_name") },
            "output_schema" => tool["output_schema"],
            "effect_profile" => McpConnection::EFFECT_PROFILE,
            "defer_loading" => true,
          }.compact
        end
      end

      def route_refusal(definitions)
        definitions.each do |entry|
          route = entry["route"]
          next unless route

          case route.fetch("kind")
          when "runner"
            public_id = route.fetch("runner_executor_public_id")
            return :runner_not_eligible unless eligible?(public_id)
            return :tool_not_served unless @routes.runner_serves?(route)
          when "mcp"
            refusal = @routes.mcp_refusal(route)
            return refusal if refusal
          else
            raise ArgumentError, "unknown tool route"
          end
        end
        nil
      end

      def environment(definitions)
        ids = [@runner_id, *definitions.filter_map { |entry| entry.dig("route", "runner_executor_public_id") }].compact.uniq
        {
          "default_runner_executor_public_id" => @runner_id,
          "executors" => ids.map { |id| executor_fact(@executors.fetch(id)) },
          "runner_candidates" => @candidate_ids.filter_map do |id|
            executor_fact(@executors.fetch(id)) if eligible?(id)
          end,
        }
      end

      def executor_fact(executor)
        { "runner_executor_public_id" => executor.public_id,
          "display_name" => executor.display_name, "environment" => executor.environment_for(:runner).deep_dup }
      end
  end
end
