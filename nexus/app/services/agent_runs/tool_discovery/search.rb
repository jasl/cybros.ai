module AgentRuns
  module ToolDiscovery
    # Discovery reads the accepted execution context, never a live profile or
    # executor announcement. Returning a schema does not broaden authority.
    class Search
      DEFAULT_LIMIT = 5
      MAX_LIMIT = 20

      def self.call(...) = new(...).call

      def initialize(node:)
        @node = node
      end

      def call
        return :not_running unless @node.status == "running"

        query = String.try_convert(@node.tool_input["query"])
        raw_limit = @node.tool_input.fetch("limit", DEFAULT_LIMIT)
        limit = Integer.try_convert(raw_limit)
        if query.blank? || limit.nil? || limit != raw_limit || !(1..MAX_LIMIT).cover?(limit)
          return settle("parameter_invalid: query must be nonempty text and limit must be an integer from 1 to #{MAX_LIMIT}.",
            is_error: true)
        end

        context = Executors::TaskOperations::Context.defaults(@node)
        catalog = Array(context.dig("environment", "skills")).group_by { |entry| entry.fetch("callable") }
        tools = Skills::Catalog.declared(context["tools"], @node.agent_run, environment: context["environment"])
        matches = matching(tools, catalog, query.strip)
        settle(bounded(matches, limit).to_json)
      end

      private

        def matching(tools, catalog, query)
          terms = query.downcase.split
          exact = tools.find { |entry| Nexus::ToolDeclarations.name_of(entry) == query }
          return [result(exact, catalog.fetch(query, []))] if exact

          tools.filter_map do |entry|
            name = Nexus::ToolDeclarations.name_of(entry)
            skills = catalog.fetch(name, [])
            function = entry["function"] || entry
            tool_text = [name, function["description"], *entry.fetch("route", {}).values].join(" ").downcase
            matching_skills = skills.select do |skill|
              text = [tool_text, skill.fetch("name"), skill.fetch("description")].join(" ").downcase
              terms.all? { |term| text.include?(term) }
            end
            next unless matching_skills.any? || terms.all? { |term| tool_text.include?(term) }

            result(entry, matching_skills)
          end
        end

        def result(entry, skills)
          { "name" => Nexus::ToolDeclarations.name_of(entry),
            "definition" => Nexus::ToolDeclarations.wire([entry]).sole,
            "route" => entry["route"], "skills" => skills }.compact
        end

        # Keep every returned schema whole. The existing result-storage bound
        # applies to the JSON text after its normal content-entry encoding.
        def bounded(matches, limit)
          answer = { "tools" => [], "truncated" => matches.length > limit }
          matches.first(limit).each do |entry|
            candidate = answer.merge("tools" => answer.fetch("tools") + [entry])
            if Nexus::SizeBounds.json_within?(Parks::Settle::RESULT_BOUND, [{ "text" => candidate.to_json }])
              answer = candidate
            else
              answer["truncated"] = true
            end
          end
          answer
        end

        def settle(text, is_error: false)
          KernelTool.settle(@node, text, title: "tool search", is_error: is_error)
        end
    end
  end
end
