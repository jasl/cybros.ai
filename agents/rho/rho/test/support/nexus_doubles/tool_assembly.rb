module NexusDoubles
  # This projection stub exercises rho's API consumption. Nexus owns and tests
  # the compiler, including collision names and frozen authority validation.
  def self.runner_tool_name(runner, name)
    "#{name[0, 49]}__#{Digest::SHA256.hexdigest("#{runner}\0#{name}")[0, 12]}"
  end

  class FakeAgentApi
    def stock_runner_unless_present(public_id, tools:)
      return if @executors.any? { |row| row.fetch("public_id") == public_id }

      @executors << NexusDoubles.remote_runner(public_id, tools: tools)
    end

    def remove_executor(public_id)
      @executors = @executors.reject { |row| row.fetch("public_id") == public_id }
    end

    private

      def tool_assembly_response(body)
        @tool_assemblies << body
        configuration = body["configuration"] || @declared_configuration || undeclared_configuration
        runner = body["default_runner_executor_public_id"]
        tools = Array(configuration["tool_definitions"]).map { |entry| assembled_custom_tool(entry) }
        tools += Array(configuration["kernel_tools"]).filter_map do |canonical|
          entry = Array(@tools).find { |candidate| candidate.fetch("canonical_name") == canonical }
          next if entry && tools.any? { |tool| tool.dig("function", "name") == entry.fetch("name") }

          entry&.fetch("definition")
        end
        document = @executors.find { |row| row.fetch("public_id") == runner }
        if runner && document.nil?
          return respond(422, { "error" => { "code" => "runner_not_eligible", "message" => "Runner is unavailable" } })
        end
        if runner && !Array(configuration["runner_executor_public_ids"]).include?(runner)
          return respond(422, { "error" => { "code" => "runner_not_declared", "message" => "Runner is not a declared candidate" } })
        end
        if document && Array(configuration["runner_executor_public_ids"]).include?(runner)
          reserved = (tools.map { |entry| entry.dig("function", "name") } + Array(@tools).map { |entry| entry.fetch("name") } + ["skill"]).uniq
          selected = configuration["runner_tool_names"]
          offered = document.fetch("served_tools").select do |entry|
            entry["description"] && entry["input_schema"] && (selected.nil? || selected.include?(entry.fetch("name")))
          end
          tools += CybrosAgent::Api::ToolLowering.function_entries(offered).map do |entry|
            name = entry.fetch("function").fetch("name")
            wire_name = reserved.include?(name) ? NexusDoubles.runner_tool_name(runner, name) : name
            entry.merge("function" => entry.fetch("function").merge("name" => wire_name), "defer_loading" => true,
              "route" => { "kind" => "runner", "runner_executor_public_id" => runner, "tool_name" => name })
          end
        end
        respond(200, { "tool_definitions" => tools, "environment" => {
          "default_runner_executor_public_id" => runner, "executors" => {},
          "runner_candidates" => Array(configuration["runner_executor_public_ids"]),
        } })
      end

      def assembled_custom_tool(entry)
        return entry unless entry["canonical"]

        source = Array(@tools).find { |tool| tool.fetch("canonical_name") == entry.fetch("canonical") }
        function = source ? source.fetch("definition").fetch("function") : { "parameters" => { "type" => "object", "properties" => {} } }
        function = function.merge(entry.fetch("function"))
        function = function.merge("description" => entry["description"]) if entry["description"]
        entry.merge("function" => function)
      end
  end
end
