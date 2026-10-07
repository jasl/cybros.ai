module Tools
  # One acceptance-time composition for profiles and authored model work.
  # Candidates describe where new work may start; only the selected Runner
  # contributes automatic tools. Explicit routes remain independent declarations.
  class Assemble
    def self.call(...) = new(...).call

    def self.for_profile(profile:, runner: nil, tool_names: nil)
      return Result.new if profile.nil?

      call(principal: profile, tool_definitions: profile.tool_definitions,
        kernel_tools: profile.kernel_tools, runner_executor_public_ids: profile.runner_executor_public_ids,
        runner_tool_names: profile.runner_tool_names, runner: runner, tool_names: tool_names)
    end

    def initialize(principal:, tool_definitions:, kernel_tools:, runner_executor_public_ids:,
                   runner_tool_names:, runner: nil, tool_names: nil)
      @principal = principal
      @explicit = Array(tool_definitions).map do |entry|
        route = entry["route"]
        route ? entry.merge("route" => route.merge("runner_executor_public_id" => route.fetch("runner_executor_public_id").downcase)) : entry
      end
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

      load_executors
      return Result.new(refusal: :runner_not_eligible) if @runner_id && !eligible?(@runner_id)

      selected = @executors[@runner_id]
      imported = runner_definitions(selected)

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

      def load_executors
        routes = @explicit.filter_map { |entry| entry["route"] }
        ids = (@candidate_ids + routes.map { |route| route.fetch("runner_executor_public_id") } + [@runner_id]).compact.uniq
        rows = TaskExecutor.where(account_id: @principal.account_id, executor_kind: :runner, public_id: ids)
          .includes(:manager).to_a
        @readiness = TaskExecutor.credential_readiness_for(rows)
        @executors = rows.index_by(&:public_id)
      end

      def eligible?(public_id)
        @executors[public_id]&.eligible_for?(@principal, readiness: @readiness)
      end

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

        offered = runner.served_tools.select { |entry| entry["description"] && entry["input_schema"] }
        if @runner_tool_names
          offered = offered.select { |entry| @runner_tool_names.include?(entry.fetch("name")) }
        end
        explicit_names = Nexus::ToolDeclarations.names(base_definitions)
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

      def route_refusal(definitions)
        definitions.each do |entry|
          route = entry["route"]
          next unless route

          public_id = route.fetch("runner_executor_public_id")
          return :runner_not_eligible unless eligible?(public_id)
          return :tool_not_served unless @executors.fetch(public_id).served?(route.fetch("tool_name"))
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
          "display_name" => executor.display_name, "environment" => executor.environment.deep_dup }
      end
  end
end
